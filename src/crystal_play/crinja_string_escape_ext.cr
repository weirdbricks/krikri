require "crinja"

# Real Python/Jinja2 string literals pass an UNRECOGNIZED backslash
# escape straight through as literal text (`'\1'` is the two characters
# `\` and `1`, since `\1` isn't a real Python string escape - no error,
# no warning in the versions Ansible targets). Vendored Crinja's own
# `BaseLexer#consume_string` drops BOTH the backslash and the following
# character entirely for any escape it doesn't recognize ("# ignore
# unknown escape") - `{{ '\1' }}` renders `""`, not `"\1"`. Found while
# porting `regex_search`'s backreference argument
# (`src/crystal_play/jinja_filters.cr`) to Crinja - real Ansible's own
# `regex_search(pattern, '\1')` syntax (a literal backslash-digit
# backreference, straight from Python's `re` module convention) silently
# became an empty group-ref string, always taking the whole-match branch
# instead of extracting the capture group.
#
# Full method replacement (same shape as `crinja_trim_blocks_ext.cr`'s
# `self.trim_text` override) - only the "ignore unknown escape" branch
# changes, to append both the backslash and the character instead of
# neither.
class Crinja::Parser::BaseLexer
  def consume_string
    @buffer.clear
    escaped = false
    delimiter = current_char

    while true
      char = next_char

      if char == Char::ZERO
        raise "Unterminated string literal"
      end

      if escaped
        escaped = false

        case char
        when 'n'
          @buffer << '\n'
        when '"', '\''
          @buffer << char
        when Symbol::STRING_ESCAPE
          @buffer << Symbol::STRING_ESCAPE
        else
          @buffer << Symbol::STRING_ESCAPE
          @buffer << char
        end
      else
        escaped = false
        case char
        when delimiter
          next_char
          break
        when Symbol::STRING_ESCAPE
          escaped = true
        else
          @buffer << char
        end
      end
    end

    @buffer.to_s
  end
end
