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
  end
end
