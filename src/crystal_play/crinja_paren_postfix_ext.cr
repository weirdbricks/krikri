require "crinja"
require "./crinja_slice_ext"

# Real Jinja2/Python allow a postfix trailer - `[index]`, `.attr`, or
# `(call)` - directly after a PARENTHESIZED subexpression, not just after
# a bare identifier (`(a + b)[0]`, `(x if y else z).attr`, all standard).
# Vendored Crinja's `parse_parenthesis_expression` builds the
# subexpression, consumes the closing `)`, and returns immediately -
# `parse_variable_expression`'s own postfix-trailer loop (`LEFT_PAREN`/
# `LEFT_BRACKET`/`POINT`, the mechanism that makes `foo[0]`/`foo.bar`
# work at all) never runs on the parenthesized result. `(collector.
# items()|list)[0]` fails with "Did not expect any more tokens, found:
# INTEGER" right at the `[0]` - found via prometheus.prometheus._common's
# own node_exporter.service.j2: `{% set name, options =
# (collector.items()|list)[0] %}` (see crinja_namespace_ext.cr - the
# tuple-target `{% set %}` feature that expression is the right-hand
# side of, found in the same live-verification pass).
#
# Full method replacement, identical to the vendored body except the
# postfix loop (copied from `parse_variable_expression`, which already
# has to have this exact loop for bare identifiers - not reachable as a
# shared private method without also overriding that method, so
# duplicated rather than refactoring vendored code neither method
# actually is).
class Crinja::Parser::ExpressionParser
  private def parse_parenthesis_expression
    if_token Kind::LEFT_PAREN do
      start_location = current_token.location

      next_token

      expression = parse_expression

      if current_token.kind == Kind::COMMA
        next_token

        exps = parse_expression_list([Kind::RIGHT_PAREN])
        entries = exps.children
        entries.unshift expression

        end_location = current_token.location

        expression = AST::TupleLiteral.new(entries).at(start_location, end_location)
      end
      expect Kind::RIGHT_PAREN

      while true
        case current_token.kind
        when Kind::LEFT_PAREN
          next_token
          expression = parse_call_expression(expression)
        when Kind::LEFT_BRACKET
          # Mirrors `crinja_slice_ext.cr`'s own `parse_variable_expression`
          # override - same slice-vs-index disambiguation (a `:` right
          # after `[`, or right after the first index expression, means
          # this is a Python slice, not a single index) - needed here too
          # since a parenthesized expression's postfix `[...]` goes
          # through THIS loop, not that one.
          next_token

          slice_start = current_token.kind == Kind::DICT_ASSIGN ? nil : parse_expression

          if current_token.kind == Kind::DICT_ASSIGN
            next_token
            slice_stop = (current_token.kind == Kind::DICT_ASSIGN || current_token.kind == Kind::RIGHT_BRACKET) ? nil : parse_expression

            slice_step = nil
            if current_token.kind == Kind::DICT_ASSIGN
              next_token
              slice_step = current_token.kind == Kind::RIGHT_BRACKET ? nil : parse_expression
            end

            index_end_location = current_token.location
            expect Kind::RIGHT_BRACKET
            expression = AST::SliceExpression.new(expression, slice_start, slice_stop, slice_step).at(expression.location_start, index_end_location)
          else
            index_end_location = current_token.location
            expect Kind::RIGHT_BRACKET
            expression = AST::IndexExpression.new(expression, slice_start.not_nil!).at(expression.location_start, index_end_location)
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
            expression = AST::MemberExpression.new(expression, member).at(expression, member)
          end
        else
          break
        end
      end

      return expression
    end

    parse_variable_expression
  end
end
