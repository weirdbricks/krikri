require "crinja"

# Real Jinja2/Python's inline conditional (ternary) expression - `<expr1>
# if <condition> else <expr2>` - is entirely unimplemented in the vendored
# Crinja shard's own parser: `parse_expression` only ever parses the
# `or`/`and`/comparison precedence chain, with no concept of the trailing
# `if ... else ...` clause at all. `{{ 'a' if x else 'b' }}` (bare, no
# surrounding block tags, no parens) fails outright ("expression was not
# fully parsed: IDENTIFIER \"if\""); wrapped in parens, `{{ ('a' if x else
# 'b') }}` fails differently ("Expected RIGHT_PAREN, got IDENTIFIER") -
# both are the same missing-grammar-rule bug, just surfacing through two
# different code paths in the parenthesized-expression parser.
#
# Found via prometheus.prometheus._common's own vars/main.yml:
# `_common_dependencies: "{% if (...) %}{{ ('python-apt' if ... else
# 'python3-apt') -}}{% else %}{% endif %}"` - a role default computed
# with the native ternary syntax (as opposed to Ansible's own `|
# ternary(...)` FILTER, which this codebase's jinja_filters.cr already
# implements separately and which is unrelated to this gap) - the whole
# expression failed to parse, so any role using it hit a hard error.
#
# Implemented here by reopening ExpressionParser/Evaluator (the sanctioned
# way to extend vendored Crinja behavior in this codebase - see
# crinja_hash_ext.cr's own doc comment) rather than editing the vendored
# lib/crinja file directly, which `shards install` would silently
# overwrite. Mirrors real Jinja2's own grammar (see Jinja2's
# parser.py#parse_condexpr): right-associative (the else-branch may itself
# be another ternary), and the `else` clause is optional (yields Undefined
# when the condition is false and there's no else).
module Crinja::AST
  expression_node CondExpr,
    condition : ExpressionNode,
    true_value : ExpressionNode,
    false_value : ExpressionNode?
end

class Crinja::Parser::ExpressionParser
  def parse_expression
    parse_condexpr.tap do |expression|
      expression.location_end = current_token.location
    end
  end

  private def parse_condexpr
    true_value = parse_logical_or

    if current_token.kind == Kind::IDENTIFIER && current_token.value == "if"
      next_token
      condition = parse_logical_or

      false_value = nil
      if current_token.kind == Kind::IDENTIFIER && current_token.value == "else"
        next_token
        false_value = parse_condexpr
      end

      true_value = AST::CondExpr.new(condition, true_value, false_value).at(true_value)
    end

    true_value
  end
end

class Crinja::Evaluator
  visit CondExpr do
    if Value.new(evaluate(expression.condition)).truthy?
      evaluate(expression.true_value)
    elsif false_value = expression.false_value
      evaluate(false_value)
    else
      Undefined.new("if-expression")
    end
  end
end

# `parse_expression` above is Crinja's single shared entry point for every
# expression-parsing context - including `{% for x in ITERABLE %}`'s own
# `ITERABLE` slot (`Tag::For::Parser#parse_for_tag`, vendored, calls
# `collection_expr = parse_expression`). That collides with the for-tag's
# own SEPARATE, real Jinja2 grammar feature - `{% for x in y if COND %}`,
# an item filter clause where COND may reference the loop variable itself
# (`{% for m in ansible_facts['mounts'] if m.mount.startswith('/home') %}`
# - prometheus.prometheus._common's own node_exporter.service.j2, the
# exact template `namespace()` needed fixing for, see
# crinja_namespace_ext.cr) - `parse_condexpr` above sees the bare `if`
# token right after the iterable and greedily treats it as an inline
# ternary's own `if`, consuming `m.mount.startswith('/home')` as the
# ternary's CONDITION and folding it into `collection_expr` itself. That:
# (a) evaluates the condition ONCE, eagerly, before the loop ever binds
# `m` at all - `Crinja::UndefinedError: m is undefined` - and (b) leaves
# nothing for the for-tag's own `if_token Kind::IDENTIFIER, "if"` check
# (further down in `parse_for_tag`) to find, so the for-loop's real
# item-filtering behavior never engages either. Two failures from one
# root cause, both hidden behind `parse_expression`'s ambiguity.
#
# Real Jinja2 has this exact same potential ambiguity in its own grammar
# and resolves it exactly the way its `parser.py#parse_for` does: parse
# the for-loop's iterable with a `with_condexpr=False` flag, so the
# ternary grammar rule doesn't fire there at all, then explicitly check
# for a literal `if` token afterward as the for-tag's own separate
# clause. Ported the same fix: a condexpr-free parse entry point, and a
# full replacement of `Tag::For::Parser#parse_for_tag` (mirrors the
# vendored method exactly, changing only which parse method builds
# `collection_expr`) that uses it.
class Crinja::Parser::ExpressionParser
  def parse_expression_no_condexpr
    parse_logical_or.tap do |expression|
      expression.location_end = current_token.location
    end
  end
end

class Crinja::Tag::For::Parser
  def parse_for_tag
    item_vars = parse_identifier_list.map do |identifier|
      if identifier.name == LOOP_VARIABLE
        raise TemplateSyntaxError.new(identifier, "cannot use reserved name `loop` as item variable in for loop")
      end
      identifier.name
    end

    expect Kind::IDENTIFIER, "in"

    collection_expr = parse_expression_no_condexpr

    if_expr : AST::ExpressionNode? = nil
    if_token Kind::IDENTIFIER, "if" do
      next_token
      if_expr = parse_expression
    end

    recursive = false
    if_token Kind::IDENTIFIER, "recursive" do
      recursive = true
    end

    close

    return {item_vars, collection_expr, if_expr, recursive}
  end
end
