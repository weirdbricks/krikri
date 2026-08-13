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
