# Single shared shell-quoting primitive. This used to exist as four
# independently-maintained copies (BasePlugin's instance method,
# PluginManager's, BatchScript's, and PluginHelpers::IptablesCommand's -
# the last of which had already drifted into a double-backslash escape
# that breaks on any embedded apostrophe), which is three chances too
# many for a security-relevant quoting function. Every shell-embedding
# call site goes through here.
module Krikri
  module Shell
    # Single-quotes *str* for shell embedding, escaping any embedded
    # single quote (POSIX `'\''` convention). Safe for arbitrary user
    # data - task param values included, not just our own base64
    # framing - since nothing inside single quotes is ever reinterpreted.
    def self.single_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end

    # Like single_quote, but leaves already-shell-safe tokens (bare words,
    # IPs/CIDRs, port lists, multi-word values such as iptables'
    # set_counters "10 20") untouched, so command strings built from
    # well-formed input stay byte-identical to their unquoted form.
    # Anything containing a shell metacharacter (including an embedded
    # apostrophe) is single-quoted with the correct `'\''` escape, so a
    # task param can never terminate the quoting and append commands.
    def self.quote_if_needed(str : String) : String
      return str if str.matches?(/\A[\w@%+=:,.\-\/ \t]*\z/)
      single_quote(str)
    end

    # Python `shlex.split` in posix mode, the way real Ansible modules
    # turn a multi-argument string param (e.g. podman_image's
    # pull_extra_args) into argv elements: whitespace-separated tokens,
    # single-quoted runs literal, double-quoted runs honoring backslash
    # escapes for \ " ` $ and newline, backslash outside quotes escaping
    # the next character. Each returned token is one argv element, ready
    # to be shell-quoted individually for embedding in a command string.
    def self.shlex_split(s : String) : Array(String)
      tokens = [] of String
      chars = s.chars
      current = IO::Memory.new
      in_token = false
      i = 0

      while i < chars.size
        c = chars[i]
        if c.whitespace?
          if in_token
            tokens << current.to_s
            current.clear
            in_token = false
          end
          i += 1
        elsif c == '\''
          in_token = true
          i = consume_single_quoted(chars, i, current)
        elsif c == '"'
          in_token = true
          i = consume_double_quoted(chars, i, current)
        elsif c == '\\'
          in_token = true
          i = consume_escape(chars, i, current)
        else
          in_token = true
          current << c
          i += 1
        end
      end

      tokens << current.to_s if in_token
      tokens
    end

    private def self.consume_single_quoted(chars : Array(Char), start : Int, current : IO::Memory) : Int
      i = start + 1
      while i < chars.size && chars[i] != '\''
        current << chars[i]
        i += 1
      end
      i + 1
    end

    private def self.consume_double_quoted(chars : Array(Char), start : Int, current : IO::Memory) : Int
      i = start + 1
      while i < chars.size && chars[i] != '"'
        if chars[i] == '\\' && i + 1 < chars.size && "\\\"`$".includes?(chars[i + 1])
          current << chars[i + 1]
          i += 2
        else
          current << chars[i]
          i += 1
        end
      end
      i + 1
    end

    private def self.consume_escape(chars : Array(Char), start : Int, current : IO::Memory) : Int
      if start + 1 < chars.size
        current << chars[start + 1]
        start + 2
      else
        start + 1
      end
    end
  end
end
