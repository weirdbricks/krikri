require "crinja"

# Real Python/Jinja2 slice syntax - `expr[start:stop]`,
# `expr[start:stop:step]`, any of the three optional (`[:22]`, `[2:]`,
# `[::-1]`) - is entirely unsupported. Vendored Crinja's
# `parse_variable_expression` only ever parses a SINGLE index expression
# inside `[...]`, so the `:` inside a slice gets lexed as `DICT_ASSIGN`
# (the same token dict-literal `key: value` pairs use) and fails outright
# ("Unexpected DICT_ASSIGN") - found via a real, common Ansible password-
# generation idiom (`('...alphabet...' | shuffle(seed=inventory_hostname)
# | join)[:22]`, dev-sec os_hardening's own `_common_basic_auth_users`
# htpasswd generation), caught only once the differential harness's
# corpus was widened to scrape whole `{% for %}` blocks (see
# scrape_corpus.py's own note - this is exactly the class of construct
# the original `{{ }}`/`{% if %}`-only corpus couldn't reach, since the
# slice sits inside a `{{ }}` nested inside a `{% for %}` body).
#
# Adds a new `SliceExpression` AST node (start/stop/step all optional)
# plus a parser-level branch in a full `parse_variable_expression`
# override (checking for `Kind::DICT_ASSIGN` right after `[` or after the
# first optional index expression) and an `Evaluator` visit implementing
# Python's slice semantics on `Array(Value)` and `String` - the two raw
# types real templates actually slice. Matches Python's negative-index
# and negative-step behavior (`[-3:]`, `[::-1]`) via a shared helper
# rather than leaning on Crystal's own `Range`-based indexing, which
# doesn't support an arbitrary step.
module Crinja::AST
  expression_node SliceExpression,
    receiver : ExpressionNode,
    slice_start : ExpressionNode?,
    slice_stop : ExpressionNode?,
    slice_step : ExpressionNode?
end

class Crinja::Parser::ExpressionParser
  private def parse_variable_expression
    identifier = parse_literal
    identifier.location_end = current_token.location

    while true
      case current_token.kind
      when Kind::LEFT_PAREN
        next_token
        identifier = parse_call_expression(identifier)
      when Kind::LEFT_BRACKET
        next_token

        if current_token.kind == Kind::DICT_ASSIGN
          slice_start = nil
        else
          slice_start = parse_expression
        end

        if current_token.kind == Kind::DICT_ASSIGN
          next_token

          slice_stop = (current_token.kind == Kind::DICT_ASSIGN || current_token.kind == Kind::RIGHT_BRACKET) ? nil : parse_expression

          slice_step = nil
          if current_token.kind == Kind::DICT_ASSIGN
            next_token
            slice_step = current_token.kind == Kind::RIGHT_BRACKET ? nil : parse_expression
          end

          end_location = current_token.location
          expect Kind::RIGHT_BRACKET
          identifier = AST::SliceExpression.new(identifier, slice_start, slice_stop, slice_step).at(identifier.location_start, end_location)
        else
          end_location = current_token.location
          expect Kind::RIGHT_BRACKET
          identifier = AST::IndexExpression.new(identifier, slice_start.not_nil!).at(identifier.location_start, end_location)
        end
      when Kind::POINT
        next_token
        member = AST::Empty.new

        if current_token.kind == Kind::IDENTIFIER || current_token.kind == Kind::INTEGER
          member = AST::IdentifierLiteral.new(current_token.value).at(current_token.location)
          member.location_end = next_token.location
        else
          unexpected_token Kind::IDENTIFIER
        end

        if member.is_a? AST::IdentifierLiteral
          identifier = AST::MemberExpression.new(identifier, member).at(identifier, member)
        end
      else
        return identifier
      end
    end
  end
end

module Crinja::PythonSlice
  # Python's slice-indexing algorithm, simplified: no clamping edge case
  # left unhandled for the realistic range of inputs real templates use
  # (out-of-range start/stop just naturally stop the loop early, same
  # observable result as Python's own clamping).
  def self.slice(items : Array(T), start : Int32?, stop : Int32?, step : Int32) : Array(T) forall T
    len = items.size
    raise Crinja::TypeError.new("slice step cannot be zero") if step == 0

    result = [] of T
    if step > 0
      i = start.nil? ? 0 : normalize(start, len)
      hi = stop.nil? ? len : normalize(stop, len)
      while i < hi
        result << items[i] if i >= 0 && i < len
        i += step
      end
    else
      i = start.nil? ? len - 1 : normalize(start, len)
      lo = stop.nil? ? -1 : normalize(stop, len)
      while i > lo
        result << items[i] if i >= 0 && i < len
        i += step
      end
    end
    result
  end

  private def self.normalize(i : Int32, len : Int32) : Int32
    i < 0 ? i + len : i
  end
end

class Crinja::Evaluator
  visit SliceExpression do
    receiver_value = value(expression.receiver)

    # Assigned via `if x = expression.slice_start` (not a `?:` ternary on
    # the method call directly) so Crystal's flow-typing narrows each
    # local variable to non-nil `ExpressionNode` inside the branch -
    # calling `value()` with the *un-narrowed* nilable property-getter
    # result directly resolves to the vendored evaluator's untyped
    # fallback overload (`def evaluate(expression); raise
    # expression.inspect; end`, `lib/crinja/src/runtime/evaluator.cr`)
    # instead of the correct concrete-type one, since only local
    # variables (not repeated method-call results) get narrowed by a
    # preceding truthy check.
    start = if node = expression.slice_start
              value(node).to_i
            end
    stop = if node = expression.slice_stop
             value(node).to_i
           end
    step = if node = expression.slice_step
             value(node).to_i
           else
             1
           end

    case raw = receiver_value.raw
    when Array(Value)
      Crinja::PythonSlice.slice(raw, start, stop, step)
    when String
      Crinja::PythonSlice.slice(raw.chars, start, stop, step).join
    when SafeString
      # A `| join`-filtered (or any other Jinja-filter-produced) string
      # is a `SafeString`, not a plain `String` - found via real Ansible
      # role syntax combining both in one expression:
      # `(alphabet | shuffle(seed=...) | join)[:22]`.
      Crinja::PythonSlice.slice(raw.to_s.chars, start, stop, step).join
    else
      raise TypeError.new(receiver_value, "'#{raw.class}' object is not sliceable")
    end
  end
end
