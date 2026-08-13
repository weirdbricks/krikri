require "crinja"

# A no-parens filter/test call (`x | somefilter`, `x is sometest`) parses
# its (optional) argument list via `parse_expression_list`, whose
# `end_tokens` set (`EOF`, `EXPR_END`, `TAG_END`, `OPERATOR`, `PIPE`,
# `TEST`, `RIGHT_BRACKET`, `RIGHT_PAREN`) has no `Kind::IDENTIFIER` entry
# at all - so a bare keyword-looking identifier that should terminate the
# call (real Jinja2 keywords like `in`/`if`/`else`/`and`/`or`/
# `recursive`, none of which are lexed as their own token `Kind` the way
# `and`/`or`/`not` happen to be - see `crinja_in_operator_ext.cr`'s own
# note on this) gets swallowed as an implicit ARGUMENT instead of
# stopping the call. Two real, independently-found symptoms of the exact
# same root cause:
#
# - `security_sshd_permit_root_login | string in ['False', 'True']` (a
#   no-parens FILTER immediately followed by `in`) - `string`'s own
#   (zero-arg) call swallows `in` as if it were an argument, corrupting
#   everything after it.
# - `value | lower if value is boolean else value` (a no-parens TEST -
#   `boolean`, itself zero-arg - immediately followed by the INLINE
#   TERNARY's own `else`) - `boolean`'s call swallows `else value` as
#   its own arguments, so `parse_condexpr`'s own `if_token ... "else"`
#   check (crinja_ternary_expr_ext.cr) never even sees an `else` token,
#   leaving `value` dangling and unparsed. This one is a considerably
#   bigger deal than the first - it breaks ANY inline ternary whose
#   condition itself is an `is`-test with a bare (no-parens) test name,
#   a common, unremarkable combination, not a rare edge case.
#
# Fixed the way real Jinja2 actually specifies this grammar: a no-parens
# test/filter call takes AT MOST the tokens up to the next recognized
# keyword, never swallowing one. Implemented narrowly - stop before
# starting to parse ANY no-parens call's argument list at all if the
# very next token is one of the reserved keyword identifiers real
# Jinja2/this codebase's own tag grammar uses (yielding a zero-argument
# call, e.g. bare `is boolean`) - rather than reproducing real Jinja2's
# full "parse exactly one primary expression" grammar for the
# often-used case where a no-parens call DOES take a single bare
# argument (`is divisibleby 3`, `is sameas other_var` - both still work
# unaffected, since neither "3" nor "other_var" is a reserved word).
class Crinja::Parser::ExpressionParser
  NO_PARENS_CALL_STOP_WORDS = {"in", "if", "else", "and", "or", "recursive"}

  private def parse_call_expression(identifier, with_parenthesis = true)
    end_tokens = if with_parenthesis
                   [Kind::RIGHT_PAREN]
                 else
                   [Kind::EOF, Kind::EXPR_END, Kind::TAG_END, Kind::OPERATOR, Kind::PIPE, Kind::TEST, Kind::RIGHT_BRACKET, Kind::RIGHT_PAREN]
                 end

    args = if !with_parenthesis && current_token.kind == Kind::IDENTIFIER && NO_PARENS_CALL_STOP_WORDS.includes?(current_token.value)
             AST::ExpressionList.new([] of AST::ExpressionNode).at(current_token.location)
           else
             parse_expression_list(end_tokens)
           end

    keyword = nil
    if_token Kind::KW_ASSIGN do
      keyword = args.children.pop
    end

    kwargs = if keyword
               parse_keyword_list(end_tokens, keyword: keyword)
             else
               Hash(AST::IdentifierLiteral, AST::ExpressionNode).new
             end

    end_location = current_token.location
    expect Kind::RIGHT_PAREN if with_parenthesis
    AST::CallExpression.new(identifier, args, kwargs).at(identifier.location_start, end_location)
  end
end
