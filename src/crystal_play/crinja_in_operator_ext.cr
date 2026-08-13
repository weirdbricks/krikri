require "crinja"

# Real Jinja2's `in`/`not in` binary operator (`x in y`, `x not in y`) is
# entirely unimplemented in vendored Crinja - not "wrong for some inputs",
# completely absent from the grammar outside `{% for x in y %}`'s own
# fixed "in" keyword. Confirmed directly: `{% if 'a' in ['a','b'] %}`
# raises Crinja::TemplateSyntaxError regardless of what's on either side
# of `in` - identifier, string literal, list literal, all fail the same
# way. Found via the differential test harness (scripts/crinja_corpus/,
# see CRINJA.md) - `in`/`not in` account for the largest single cluster
# of raw-Crinja divergences from real Jinja2 in that harness's corpus.
#
# This is surprising for a codebase that's survived 21 real-host
# benchmark rounds because most Ansible `when:`/task-param conditionals
# route through this codebase's OWN hand-rolled ConditionalEvaluator
# (which has its own, independent `in` support - see
# conditional_evaluator.cr), not through Crinja at all. Only real `.j2`
# template files go through Crinja, and apparently none of the 21 rounds'
# templates happened to combine `{% if %}`/`{{ }}` with `in` in a way
# that got noticed - until this harness scraped real template source
# directly instead of waiting for a live symptom.
#
# Fixed the same way as the ternary patch (crinja_ternary_expr_ext.cr):
# reopen the parser to add a new grammar rule, reopen AST/Evaluator
# plumbing where needed. Unlike ternary, no new AST node type is needed -
# `AST::ComparisonExpression` (operator : String, left, right) already
# has the right shape, and `Evaluator#visit BinaryExpression,
# ComparisonExpression` already dispatches generically through
# `@env.operators[expression.operator]` - so this patch only needs a new
# `Operator::In`/`Operator::NotIn` pair plus a parser-level insertion of
# the `in`/`not in` grammar rule.
#
# Precedence: real Jinja2 puts `in`/`not in` at the same "comparison"
# level as `==`/`!=`/`<`/`>`. Crinja's own precedence chain (see
# expression_parser.cr) already splits that into two separate levels
# (`equal_not` above `less_greater`, not how real Jinja groups them, a
# separate pre-existing quirk out of scope here) - `in`/`not in` is
# inserted into the `less_greater` level, full method replacement
# (mirrors that method's macro-generated body, since `parse_operator`'s
# macro can't be re-invoked with extra cases from outside the class).
class Crinja::Parser::ExpressionParser
  # Vendored Crinja's `parse_equal_not` (macro-generated, see
  # expression_parser.cr's `parse_operator :equal_not, :less_greater,
  # EQUAL, NOT_EQUAL, NOT`) treats bare `not` as one of ITS OWN binary
  # comparison operators, alongside `==`/`!=` - real Jinja2 has no such
  # binary "not" comparator at all (`not` is either the unary prefix or
  # part of `is not`/`not in`, both handled elsewhere in the grammar).
  # This is genuinely dead/buggy in a way that only surfaces on `X not in
  # Y` (`"enabled" not in options`): the equal_not level greedily
  # consumes "not" as its own operator token before `parse_less_greater`
  # (this file's own "in"/"not in" addition below) ever gets a chance to
  # see it, builds `ComparisonExpression("not", left, right)`, and then
  # crashes at evaluation with a raw `Exception: unreachable: invalid
  # operator` (`Operator::Not` is `Unary`, not `Binary`/`Logic`, so
  # `@env.operators["not"]` matches neither case in
  # `Evaluator#visit BinaryExpression, ComparisonExpression`). Full
  # method replacement (the macro can't be re-invoked with a shorter
  # operator list from outside the class) - identical body to the
  # vendored one, minus `NOT` from the `case` arm.
  private def parse_equal_not
    left = parse_less_greater

    while true
      if current_token.kind == Kind::OPERATOR
        case current_token.value
        when Symbol::OP_EQUAL, Symbol::OP_NOT_EQUAL
          operator = current_token.value
          next_token
          right = parse_less_greater
          left = AST::ComparisonExpression.new(operator, left, right).at(left, right)
        else
          return left
        end
      else
        return left
      end
    end
  end

  # Real Jinja2/Python's unary `not` binds LOOSER than a comparison, so
  # `not a in b` means `not (a in b)`, not `(not a) in b`. Vendored
  # Crinja's `parse_unary_expression` sits at the bottom of the
  # precedence chain (just above `parse_pow`/atoms) with no such
  # broadening for its `Symbol::OP_NOT` case - `not 'z' in ['a', 'b']`
  # parsed as `(not 'z') in ['a', 'b']` (`not 'z'` truthy-negates the
  # tight string literal to a bare `false`, then checks `false in [...]`)
  # instead of the intended `not ('z' in ['a', 'b'])`.
  #
  # The exact same misplaced-precedence bug applies to `is`/`is not`
  # TESTS too, not just `in` - `not collector is mapping` parsed as
  # `(not collector) is mapping` instead of `not (collector is mapping)`
  # (confirmed directly: `Crinja.new.from_string("{% if not 'x' is
  # mapping %}T{% else %}F{% endif %}").render` returned `"F"`, not the
  # correct `"T"`) - a wrong INITIAL claim in this comment (this file's
  # own prior revision asserted "is"/"is not" "already worked correctly"
  # without actually testing it) that a live real-host verification run
  # caught: prometheus.prometheus.node_exporter's own node_exporter.
  # service.j2 has `{% if not collector is mapping %}` guarding its
  # scalar-vs-dict collector branch, and it silently took the WRONG
  # branch. Tests sit one level higher than `in`/`not in` in Crinja's own
  # chain (`parse_filter`, which calls `parse_unary_expression` for ITS
  # `left` and applies `|`/`is` on top of whatever comes back) - so
  # fixing this means recognizing a trailing TEST here too and
  # replicating `parse_filter`'s own TEST-branch logic (duplicated
  # rather than shared, same reasoning as the `in`/`not in` case: no
  # existing method boundary to call into without a bigger refactor of
  # vendored code).
  #
  # Both fixes scoped narrowly to the two constructs real roles were
  # found using (`not k in [...]`, `not collector is mapping`) rather
  # than a full precedence-chain rewrite, which would risk regressing
  # whatever the existing low-precedence placement was relied on for
  # elsewhere.
  private def parse_unary_expression
    start_location = current_token.location

    if current_token.kind == Kind::OPERATOR
      case operator = current_token.value
      when Symbol::OP_PLUS, Symbol::OP_MINUS, Symbol::OP_NOT
        next_token
        value = parse_unary_expression

        if operator == Symbol::OP_NOT && current_token.kind == Kind::IDENTIFIER && current_token.value == "in"
          next_token
          right = parse_tilde
          value = AST::ComparisonExpression.new("in", value, right).at(value, right)
        end

        if operator == Symbol::OP_NOT && current_token.kind == Kind::TEST
          next_token

          not_location = nil
          if_token Kind::OPERATOR, "not" do
            not_location = current_token.location
            next_token
          end

          identifier = if_token(Kind::NONE) do
            AST::IdentifierLiteral.new(current_token.value).at(current_token.location)
          end || assert_token(Kind::IDENTIFIER) do
            AST::IdentifierLiteral.new(current_token.value).at(current_token.location)
          end
          identifier.location_end = next_token.location

          call = parse_call_expression identifier, with_parenthesis: false

          value = AST::TestExpression.new(value, identifier, call.argumentlist, call.keyword_arguments).at(value, call)
          value = AST::UnaryExpression.new("not", value).at(not_location, value.location_end) if not_location
        end

        return AST::UnaryExpression.new(operator, value).at(start_location, value.location_end)
      when Symbol::OP_TIMES
        # splash operator
        next_token
        value = parse_unary_expression
        return AST::SplashOperator.new(value).at(start_location, value.location_end)
      else
        # continue with next rule
      end
    end

    parse_pow
  end

  private def parse_less_greater
    left = parse_tilde

    while true
      if current_token.kind == Kind::OPERATOR
        case current_token.value
        when Symbol::OP_LESS, Symbol::OP_GREATER, Symbol::OP_LESS_EQUAL, Symbol::OP_GREATER_EQUAL
          operator = current_token.value
          next_token
          right = parse_tilde
          left = AST::ComparisonExpression.new(operator, left, right).at(left, right)
          next
        end
      end

      if current_token.kind == Kind::IDENTIFIER && current_token.value == "in"
        next_token
        right = parse_tilde
        left = AST::ComparisonExpression.new("in", left, right).at(left, right)
        next
      end

      if current_token.kind == Kind::OPERATOR && current_token.value == Symbol::OP_NOT &&
         (peeked = peek_token?) && peeked.kind == Kind::IDENTIFIER && peeked.value == "in"
        next_token # consume "not"
        next_token # consume "in"
        right = parse_tilde
        left = AST::ComparisonExpression.new("not in", left, right).at(left, right)
        next
      end

      return left
    end
  end
end

class Crinja::Operator
  # Containment check shared by `In`/`NotIn` - checks Hash key membership,
  # String substring, and falls back to element-equality search over any
  # other iterable (real Jinja2's own `in` behaves the same way: dict ->
  # key check, string -> substring check, anything else -> `__contains__`/
  # iteration).
  def self.contains?(container : Crinja::Value, item : Crinja::Value) : Bool
    case raw = container.raw
    when Hash
      raw.has_key?(item)
    when String
      needle = item.raw.is_a?(String) ? item.raw.as(String) : item.to_s
      raw.includes?(needle)
    else
      container.each.any? { |value| value == item }
    end
  end

  class In < Operator
    include Binary
    name "in"

    def value(env : Crinja, op1 : Value, op2 : Value)
      Value.new Operator.contains?(op2, op1)
    end
  end

  class NotIn < Operator
    include Binary
    name "not in"

    def value(env : Crinja, op1 : Value, op2 : Value)
      Value.new !Operator.contains?(op2, op1)
    end
  end
end

# `Operator::Library#register_defaults` (generated by the vendored
# `register_default [Plus, Minus, ...]` macro call in operator.cr) embeds
# that operator list as a literal array directly in the method body -
# unlike Filter::Library/Test::Library, it does NOT read from the
# `@@defaults` class array that `Crinja.filter`/`Crinja.test` append to,
# so pushing onto `Operator::Library.defaults` here would silently do
# nothing. `previous_def` (Crystal's standard way to extend rather than
# replace a reopened method) is what actually wires these into every
# `Crinja.new` instance.
class Crinja::Operator::Library
  def register_defaults
    previous_def
    self << Crinja::Operator::In.new
    self << Crinja::Operator::NotIn.new
  end
end
