#!/usr/bin/env crystal

require "json"
require "system/user"
require "system/group"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/python_codecs"

module Krikri
  # Replace Plugin - Replace each regex match in a file with a replacement
  # string, matching ansible.builtin.replace semantics.
  #
  # Parameters:
  #   path (required): File to operate on
  #   regexp (required): Regex pattern to match (re.MULTILINE semantics)
  #   replace (optional): Replacement string (default: empty, i.e. delete
  #     matches). `\1`, `\2` etc. are backreferences to capture groups.
  #   after (optional): Only the portion AFTER the first match of this
  #     regex is subject to the regexp substitution (re.DOTALL semantics)
  #   before (optional): Mirror of `after` - substitution confined to the
  #     portion BEFORE the first match (re.DOTALL). With both, the
  #     substitution runs on the region between them.
  #   backup (optional, default no): timestamped backup of the original
  #     before any write, reported as `backup_file` in the result
  #   validate (optional): shell command template containing %s run
  #     against a staged temp copy; non-zero exit fails the task without
  #     touching the real file
  #   encoding (optional, default utf-8): encoding used to read/write
  #   owner/group/mode (optional): attribute changes to apply after the
  #     write (real replace.py's add_file_common_args=True)
  #   check_mode (optional): Dry-run mode
  #
  # Only rewrites the file when the substitution actually changes its
  # contents (idempotent), matching real Ansible: a "changed" result means
  # the file was modified, and re-running with no remaining matches reports
  # changed: false. Real Ansible fails if the file doesn't exist.
  class ReplacePlugin < BasePlugin
    # ansible.builtin.replace's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.replace). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[backup unsafe_writes]
    end

    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
    end

    def execute : PluginResult
      validate_bool_params!
      # Real ansible's replace module rejects ANY parameter outside its
      # own argument_spec at module-arg validation, before any action
      # runs - notably `ignorecase:`, which belongs to lineinfile, not
      # replace, so a role that copies lineinfile's params onto a
      # replace task fails loudly under real Ansible while this engine
      # silently ignored the unknown key and ran anyway. Found via the
      # podman-diff replace_edge_cases R9 harness case; message live-
      # verified against the real module's own output for this exact
      # task. check_mode/diff_mode/_verbosity/_environment are engine-
      # internal keys injected by the executor (see build_plugin_config),
      # not part of the real argument_spec, so none are rejected. The
      # parenthesized alias list mirrors real Ansible's msg (attr, dest,
      # destfile, name).
      replace_supported = {"after", "attributes", "backup", "before", "encoding", "group", "mode", "owner", "path", "regexp", "replace", "selevel", "serole", "setype", "seuser", "unsafe_writes", "validate", "attr", "dest", "destfile", "name"}
      replace_internal = {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}
      unsupported = @params.keys.reject { |k| replace_supported.includes?(k) || replace_internal.includes?(k) }
      unless unsupported.empty?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (ansible.builtin.replace) module: #{unsupported.sort.join(", ")}. " \
               "Supported parameters include: after, attributes, backup, before, encoding, group, mode, owner, " \
               "path, regexp, replace, selevel, serole, setype, seuser, unsafe_writes, validate " \
               "(attr, dest, destfile, name)."
        )
      end

      # path (aliases: dest, name) - matches real Ansible's own
      # argument_spec, where `dest:` is the long-standing legacy alias
      # most existing playbooks/roles still write (lineinfile.cr already
      # supports the same three spellings). Found via konstruktoid-
      # hardening's own "Set default bash.bashrc umask" task, which uses
      # `dest:` - "Missing required parameter: path" even though the
      # task supplied a perfectly valid (if not the newest-spelling)
      # target file parameter.
      path = @params["path"]? || @params["dest"]? || @params["name"]?
      unless path
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: path"
        )
      end
      path = expand_tilde(path)

      pattern = @params["regexp"]?
      unless pattern
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: regexp"
        )
      end

      # Real Ansible's replace fails on a directory (rc=256) before the
      # existence check (rc=257) - replace.py's own main() ordering.
      if Dir.exists?(path)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Path #{path} is a directory !",
          rc: 256
        )
      end

      # Real Ansible's replace fails if the file doesn't exist (no `creates`
      # tolerance), and that failure isn't recoverable without the file
      # appearing - so it raises rather than silently no-op'ing.
      unless File.exists?(path)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Path #{path} does not exist !",
          rc: 257
        )
      end

      encoding = @params["encoding"]?.presence || "utf-8"

      # real replace.py decodes the file's bytes with this name inside
      # to_text(), so a name CPython has no codec for dies with a
      # LookupError there - which its own `except OSError` does NOT
      # catch, i.e. the module crash path, reaching the user as real's
      # "Task failed: Module failed: unknown encoding: 20" (msg and
      # [ERROR] line live-verified against 2.19.11). Deciding that
      # verdict from Crystal's own encoding set instead (the old
      # behavior: any name iconv rejects was reported as "Failed to
      # read <path>: Invalid encoding: <name>") gets it wrong both
      # ways - it never matched real's wording, and it failed the task
      # for every name Python resolves but this host's iconv does not
      # take verbatim ("latin-1", "cp1252", "us-ascii", ...).
      unless PythonCodecs.known?(encoding)
        detail = "unknown encoding: #{encoding}"
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Task failed: Module failed: #{detail}",
          _ansible_error_detail: detail
        )
      end
      # The spelling iconv converts with, or nil for a codec Python
      # resolves but no iconv here can - the file's bytes are then read
      # and written verbatim, which is the same round trip real's
      # decode/encode pair produces for a single-byte codec.
      iconv_encoding = PythonCodecs.iconv_name(encoding)

      # real replace.py decodes the file's BYTES with
      # to_text(..., errors="surrogate_or_strict", encoding=...), which
      # resolves to surrogateescape on every CPython: a byte the codec
      # cannot decode becomes a lone surrogate and the substitution
      # proceeds (to_bytes() on the way out turns each surrogate back
      # into its original byte). So a UTF-8 file holding a latin-1 byte
      # still replaces like real, where this engine used to abort with
      # a PCRE "UTF-8 error" the moment the regex touched the decoded
      # bytes - and codecs Python resolves but iconv cannot (mac_roman,
      # utf_8_sig, ...) keep their byte-for-byte round trip instead of
      # failing the regex the same way. PCRE2 aborts a match whose
      # subject holds raw surrogate codepoints, so each undecodable byte
      # maps to the private-use twin U+F780+(byte-0x80) instead of
      # Python's U+DC80+(byte-0x80): one undecodable byte is one
      # character to the regex either way, and encode() on write
      # restores the original bytes exactly.
      raw_content = begin
        File.read(path)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read #{path}: #{ex.message}"
        )
      end

      surrogate = false
      content = if ie = iconv_encoding
                  if ie == "utf-8" || ie == "ascii"
                    surrogate = true
                    SurrogateText.decode(raw_content)
                  else
                    begin
                      io = IO::Memory.new(raw_content.to_slice)
                      io.set_encoding(ie)
                      io.gets_to_end
                    rescue
                      # iconv has no converter for a codec Python does
                      # have on this host, or the bytes do not decode
                      # under it - real decodes with surrogateescape and
                      # proceeds, so keep byte-level semantics instead
                      # of failing.
                      surrogate = true
                      SurrogateText.decode(raw_content)
                    end
                  end
                else
                  surrogate = true
                  SurrogateText.decode(raw_content)
                end

      # before/after sectioning - replace.py builds a DOTALL wrapper regex
      # around a (?P<subsection>...) capture and runs the substitution on
      # the captured region only. Python's greedy `.*` under re.search
      # matches everything up to the LAST occurrence of `before`, and the
      # non-greedy `.*?` between both anchors stops at the FIRST `before`
      # after the first `after` - PCRE's quantifier semantics are
      # identical, so the same patterns are used verbatim here (DOTALL,
      # not MULTILINE_ONLY: `.` must cross newlines in these wrappers,
      # exactly as replace.py's re.DOTALL does).
      after_pattern = @params["after"]?.presence
      before_pattern = @params["before"]?.presence

      section = content
      section_start = 0
      section_end = content.bytesize

      if after_pattern || before_pattern
        section_pattern = if after_pattern && before_pattern
                            "#{after_pattern}(?P<subsection>.*?)#{before_pattern}"
                          elsif after_pattern
                            "#{after_pattern}(?P<subsection>.*)"
                          else
                            "(?P<subsection>.*)#{before_pattern}"
                          end

        # real replace.py compiles the section pattern OUTSIDE its
        # `except re.error` (and before the regexp itself), so a bad
        # after:/before: kills the module through the crash wrapper -
        # live-verified vs 2.19.11: after: 'unmatched (' gives "Task
        # failed: Module failed: missing ), unterminated subpattern at
        # position 10" (the position of the '(' inside the composed
        # pattern). PythonPattern.scan rejects first what PCRE2 would
        # happily compile (real's Python rejects it, same crash).
        section_scan = PythonPattern.scan(section_pattern)
        if err = section_scan.error
          return crash_result(err)
        end
        section_regex = begin
          Regex.new(section_scan.translated, Regex::CompileOptions::DOTALL)
        rescue ex
          return crash_result(python_pcre_error(ex.message.not_nil!, section_scan))
        end

        match = section_regex.match(content)
        unless match
          # Real's no-match exit also carries an `rc: 0` alongside the
          # msg (the module's run_command convention; live-verified vs
          # 2.19.11 at -v).
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Pattern for before/after params did not match the given file: #{section_pattern}",
            rc: 0,
            key_order: SUCCESS_KEY_ORDER
          )
        end

        section_start = match.begin(1).not_nil!
        section_end = match.end(1).not_nil!
        section = content.byte_slice(section_start, section_end - section_start)
      end

      # Real Ansible compiles the regexp with re.MULTILINE (replace.py), so
      # ^ and $ anchor at every line boundary, not just the start/end of the
      # whole file - e.g. inmotionhosting.apache's "Listen 443$" against
      # /etc/apache2/ports.conf, whose Listen lines sit indented inside
      # <IfModule> blocks and are not the last line of the file.
      # MULTILINE_ONLY, not MULTILINE: Crystal's MULTILINE constant implies
      # DOTALL (regex.cr maps it to PCRE MULTILINE | DOTALL), which would
      # let "." cross newlines and eat trailing content on replacement.
      #
      # re.compile of the regexp sits OUTSIDE replace.py's `except
      # re.error` too, so a bad pattern is an uncaught re.error - the
      # module-crash wrapper ("Task failed: Module failed: missing ),
      # unterminated subpattern at position 10" for regexp: 'unmatched (',
      # live-verified vs 2.19.11), not this engine's old "Invalid regular
      # expression: ..." fail_json. PythonPattern.scan rejects first what
      # PCRE2 would happily compile (real's Python rejects it first, same
      # crash), and a PCRE2 compile error is translated into Python's own
      # wording/position where the mapping is exact.
      pattern_scan = PythonPattern.scan(pattern)
      if err = pattern_scan.error
        return crash_result(err)
      end
      regex = begin
        Regex.new(pattern_scan.translated, Regex::CompileOptions::MULTILINE_ONLY)
      rescue ex
        return crash_result(python_pcre_error(ex.message.not_nil!, pattern_scan))
      end

      # Real replace.py feeds the `replace:` string through Python re.sub's
      # own replacement-template parser, which runs BEFORE the pattern is
      # ever applied to the content - so a template the pattern cannot
      # satisfy fails the task even when the pattern matches nothing
      # ("invalid group reference 1 at position 1" for `regexp: kpg` +
      # `replace: '\1 changed'`, msg live-verified against 2.19.11,
      # where the same task succeeded here and rewrote the file). The
      # parser also interprets the control escapes - so in YAML single
      # quotes '\t' (two literal chars: backslash, t) lands in the file
      # as a REAL tab byte; Round900159 juju4.harden_apache's
      # apache-security.yml failed real `apache2ctl -t` on this engine
      # with `Invalid command '\tOptions'` for exactly that reason.
      replace = begin
        ReplacementTemplate.parse(@params["replace"]? || "", regex.capture_count, ReplacementTemplate.named_groups(pattern))
      rescue ex : ReplacementTemplate::RegexError
        # re.error, which replace.py DOES catch and re-raise as a
        # fail_json of its own.
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unable to process replace due to error: #{ex.message}"
        )
      rescue ex : ReplacementTemplate::CrashError
        # Anything else the parser raises (IndexError for a group name
        # the pattern does not define) escapes replace.py's
        # `except re.error`, so it is a module CRASH, not a fail_json:
        # "unknown group name 'x'", wrapped as real wraps it.
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Task failed: Module failed: #{ex.message}",
          _ansible_error_detail: ex.message
        )
      end

      # Real counts replacements with re.subn and requires BOTH a
      # non-zero count and an actually-changed section before calling
      # it changed (replace.py: `if result[1] > 0 and section !=
      # result[0]`).
      match_count = section.scan(regex).size
      new_section = section.gsub(regex, replace)
      changed = match_count > 0 && new_section != section

      backup_file = ""
      if changed && !@check_mode
        # Real Ansible's backup_local runs before write_changes, so the
        # backup always holds the PRE-substitution content.
        if true?(@params["backup"]?)
          backup_file = write_backup(path)
        end

        if failure = write_with_optional_validate(path, new_section, section_start, section_end, content, iconv_encoding, surrogate)
          return failure
        end
      end

      # Apply any requested attribute changes (owner/group/mode), matching
      # real Ansible which also sets them even on a no-matches run
      # (check mode never writes).
      attr_changed = @check_mode ? false : apply_attributes(path)

      # Real's result carries ONLY rc/msg/changed (+diff in diff mode,
      # +backup_file when a backup was actually taken) - no path echo,
      # no file-common stat fields. msg is "N replacements made" (the
      # subn count), "" when nothing changed, with check_file_attrs
      # appending the ownership/perms suffix when the attributes were
      # what drifted (live-verified vs 2.19.11 at -v).
      msg = if changed
              "#{match_count} replacements made"
            else
              ""
            end
      if attr_changed
        msg += " and " unless msg.empty?
        msg += "ownership, perms or SE linux context changed"
      end
      result = PluginResult.new(
        changed: changed || attr_changed,
        failed: false,
        msg: msg,
        include_empty_msg: true,
        rc: 0,
        key_order: SUCCESS_KEY_ORDER
      )
      result.extra["backup_file"] = JSON::Any.new(backup_file) unless backup_file.empty?
      result
    end

    # Real ansible.builtin.replace's registered-result key order
    # (live-verified vs 2.19.11 via `{{ r | to_json }}` on registered
    # replace: tasks): rc leads, then backup_file only when a backup was
    # taken, then msg (empty string included on a no-matches run), then
    # changed, failed. Identical on changed, unchanged, no-match and
    # check-mode runs; no diff key outside --diff mode, no path echo, no
    # stat fields.
    private SUCCESS_KEY_ORDER = %w[rc backup_file msg changed failed]

    # The module-crash wrapper: real's executor renders an exception that
    # escapes the module (a bad re.compile of regexp:/after:/before:, an
    # unknown codec, an IndexError from the replacement template) as
    # "Task failed: Module failed: <text>" with no rc key - distinct from
    # replace.py's own fail_json paths (live-verified vs 2.19.11).
    private def crash_result(detail : String) : PluginResult
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Task failed: Module failed: #{detail}",
        _ansible_error_detail: detail
      )
    end

    # Translates a PCRE2 compile error (Crystal's wording, " at <byte
    # offset>" suffix) into the re.error text Python's own parser raises
    # for the same pattern, wherever the mapping is exact. PCRE2's
    # offsets count BYTES; Python's re.error positions count CHARACTERS
    # of the pattern as the user wrote it, so the offset goes byte ->
    # translated char -> source char (the \uXXXX/\Uhhhhhhhh rewrites can
    # move it). Cases without an exact mapping keep the PCRE2 wording -
    # still inside the crash wrapper, which is the part users actually
    # script against.
    private def python_pcre_error(pcre_message : String, scan : PythonPattern::Scan) : String
      match = pcre_message.match(/\A(.+) at (\d+)\z/)
      return pcre_message unless match

      text = match[1]
      char_offset = scan.translated.byte_slice(0, match[2].to_i).size
      case text
      when "missing closing parenthesis"
        # Python points at the INNERMOST unterminated '(' - "a(b" at 2,
        # "unmatched (" at 10 - which PCRE2's end-of-pattern offset does
        # not carry; the scan tracked the '(' stack instead.
        position = scan.unclosed_paren || char_offset
        "missing ), unterminated subpattern at position #{position}"
      when "missing terminating ] for character class"
        position = scan.open_class_start || char_offset
        "unterminated character set at position #{position}"
      when "unmatched closing parenthesis"
        # Both engines point at the stray ')' itself.
        "unbalanced parenthesis at position #{PythonPattern.source_index(scan, char_offset)}"
      when "quantifier does not follow a repeatable item"
        repeat_error(scan, char_offset)
      when "unrecognized character follows \\"
        backslash = PythonPattern.source_index(scan, (char_offset - 1).clamp(0, Int32::MAX))
        offending = scan.translated[char_offset]? || ""
        "bad escape \\#{offending} at position #{backslash}"
      when "\\ at end of pattern"
        backslash = PythonPattern.source_index(scan, (char_offset - 1).clamp(0, Int32::MAX))
        "bad escape (end of pattern) at position #{backslash}"
      when "numbers out of order in {} quantifier"
        chars = scan.translated.chars
        j = char_offset - 1
        while j >= 0 && chars[j]? != '{'
          j -= 1
        end
        d = j + 1
        while d < chars.size && !chars[d].ascii_number?
          d += 1
        end
        position = d < chars.size ? PythonPattern.source_index(scan, d) : char_offset
        "min repeat greater than max repeat at position #{position}"
      else
        pcre_message
      end
    end

    # PCRE2 collapses Python's two quantifier errors into one message;
    # the shape of the char before the quantifier tells them apart the
    # way Python's parser does (a quantifier right after a quantifier is
    # "multiple repeat" - except a trailing ? (lazy) or + (possessive,
    # which PCRE2 accepts outright so it never reaches here) - anything
    # else non-repeatable is "nothing to repeat").
    private def repeat_error(scan : PythonPattern::Scan, char_offset : Int32) : String
      chars = scan.translated.chars
      source = PythonPattern.source_index(scan, char_offset)
      if char_offset.zero?
        return "nothing to repeat at position #{source}"
      end
      prev = chars[char_offset - 1]
      if prev.in?('*', '+', '?') || (prev == '}' && PythonPattern.quantifier_brace?(chars, char_offset - 1))
        "multiple repeat at position #{source}"
      else
        "nothing to repeat at position #{source}"
      end
    end

    # CPython's `re` replacement-template parser (re._parser.Tokenizer plus
    # parse_template), ported so a `replace:` value behaves like the
    # re.subn call real replace.py makes: the control escapes are
    # interpreted here, and every group reference is checked against the
    # pattern's own captures BEFORE the substitution runs - which is why
    # an unsatisfiable reference fails the task even when the pattern
    # matched nothing (real-verified against 2.19.11: `regexp: kpg` +
    # `replace: '\1 changed'` fails with "invalid group reference 1 at
    # position 1" and the file is left untouched).
    #
    # The parser has two failure classes because real's replace.py
    # handles them differently: everything raised as an re.error is
    # caught by its own `except re.error` and re-raised through
    # fail_json ("Unable to process replace due to error: <text>"), while
    # the IndexError for an undefined group name escapes that handler and
    # crashes the module with the bare text.
    private class ReplacementTemplate
      DIGITS        = "0123456789"
      OCT_DIGITS    = "01234567"
      ASCII_LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
      # sre_parse.MAXGROUPS
      MAX_GROUPS = 2_147_483_647_i64

      # re.error - the one replace.py catches.
      class RegexError < Exception
      end

      # The IndexError a group name the pattern does not define raises:
      # NOT caught by replace.py, so it kills the module instead.
      class CrashError < Exception
      end

      # re._parser.ESCAPES. \0 / \digits (octal and group references) and
      # \g<...> have their own branches; a non-letter escape with no
      # entry here ("\\ ", "\\-") stays literal in real too.
      ESCAPES = {
        'a' => '\a', 'b' => '\b', 'f' => '\f', 'n' => '\n',
        'r' => '\r', 't' => '\t', 'v' => '\v', '\\' => '\\',
      }

      @chars : Array(Char)
      @index : Int32

      # The token the tokenizer looks at: a single character, or a
      # backslash plus the character it escapes. nil at end of input.
      getter token : String?

      def self.parse(source : String, groups : Int32, named_groups : Set(String)) : String
        new(source).parse(groups, named_groups)
      end

      # The named capture groups a pattern defines, in the three
      # spellings Python accepts ((?P<name>), (?<name>), (?'name')).
      # Scanned off the pattern text because Crystal's Regex exposes the
      # capture COUNT (Regex#capture_count) but not the names, and the
      # template parser has to know whether a `\g<name>` reference
      # exists (real raises IndexError - not fail_json - when it does
      # not).
      def self.named_groups(pattern : String) : Set(String)
        names = Set(String).new
        chars = pattern.chars
        index = 0
        in_class = false
        while index < chars.size
          char = chars[index]
          case char
          when '\\'
            index += 2
            next
          when '['
            in_class = true
          when ']'
            in_class = false
          when '('
            if !in_class && chars[index + 1]? == '?'
              marker = chars[index + 2]?
              named = marker == '<' || marker == '\'' || (marker == 'P' && chars[index + 3]? == '<')
              if named
                closer = marker == '\'' ? '\'' : '>'
                name_start = marker == 'P' ? index + 4 : index + 3
                name_end = name_start
                while name_end < chars.size && chars[name_end] != closer
                  name_end += 1
                end
                names << chars[name_start...name_end].join if name_end < chars.size
                index = name_end
              end
            end
          end
          index += 1
        end
        names
      end

      private def initialize(source : String)
        @chars = source.chars
        @index = 0
        advance
      end

      def parse(groups : Int32, named_groups : Set(String)) : String
        String.build do |text|
          loop do
            current = take
            break unless current
            if current[0] != '\\'
              text << current
              next
            end

            case char = current[1]
            when 'g' then parse_named_reference(text, groups, named_groups)
            when '0' then parse_zero_escape(text)
            else
              if DIGITS.includes?(char)
                parse_numbered_reference(text, groups, char)
              elsif (escaped = ESCAPES[char]?)
                text << escaped
              elsif ASCII_LETTERS.includes?(char)
                raise re_error("bad escape \\#{char}", current.size)
              else
                text << current
              end
            end
          end
        end
      end

      private def advance : Nil
        if @index >= @chars.size
          @token = nil
          return
        end
        start = @index
        if @chars[start] == '\\'
          @index += 1
          if @index >= @chars.size
            # A lone trailing backslash, reported by the tokenizer
            # itself (real-verified: `replace: 'a\'` fails with "bad
            # escape (end of pattern) at position 1").
            raise RegexError.new("bad escape (end of pattern) at position #{@chars.size - 1}")
          end
        end
        @index += 1
        @token = @chars[start...@index].join
      end

      private def take : String?
        current = @token
        advance
        current
      end

      # Tokenizer#tell: where the pending token starts, minus the
      # caller's offset - real counts every reported position from there.
      private def position(offset : Int32 = 0) : Int32
        (@index - (token.try(&.size) || 0)) - offset
      end

      private def re_error(message : String, offset : Int32 = 0) : RegexError
        RegexError.new("#{message} at position #{position(offset)}")
      end

      # Tokenizer#match: true when the pending token is this one
      # character (consuming it).
      private def match(char : Char) : Bool
        return false unless token == char.to_s
        advance
        true
      end

      # Tokenizer#getuntil.
      private def getuntil(terminator : Char, label : String) : String
        result = [] of Char
        loop do
          current = take
          if current.nil?
            raise re_error("missing #{label}") if result.empty?
            raise re_error("missing #{terminator}, unterminated name", result.size)
          end
          if current[0] == terminator
            raise re_error("missing #{label}", 1) if result.empty?
            break
          end
          result << current[0]
        end
        result.join
      end

      # \0, \01, \012 - up to three octal digits in total, masked to a
      # byte exactly as real's `chr(int(this[1:], 8) & 0xff)` is.
      private def parse_zero_escape(text : String::Builder) : Nil
        digits = ['0']
        digits << take.not_nil![0] if digit?(OCT_DIGITS)
        digits << take.not_nil![0] if digit?(OCT_DIGITS)
        text << (digits.join.to_i(8) & 0xff).chr
      end

      # \1 .. \99 - a group reference, unless the digits spell an octal
      # escape (three octal digits).
      private def parse_numbered_reference(text : String::Builder, groups : Int32, first : Char) : Nil
        digits = String.build { |buffer| buffer << first }
        if digit?(DIGITS)
          digits = "#{digits}#{take}"
          if OCT_DIGITS.includes?(first) && OCT_DIGITS.includes?(digits[1]) && digit?(DIGITS)
            digits = "#{digits}#{take}"
            value = digits.to_i(8)
            if value > 0o377
              raise re_error("octal escape value \\#{digits} outside of range 0-0o377", digits.size + 1)
            end
            text << value.chr
            return
          end
        end
        # Emitted unchanged: Crystal's own gsub replacement parser
        # expands \0-\9, and reads a digit right after one as literal
        # text - exactly as Python does once the template is parsed.
        text << '\\' << digits
        index = digits.to_i
        raise re_error("invalid group reference #{index}", digits.size) if index > groups
      end

      # \g<1> / \g<name> - Python's unambiguous spelling of the same
      # reference, validated the same way and then rewritten into the
      # form Crystal's gsub expands (\N, \k<name>).
      private def parse_named_reference(text : String::Builder, groups : Int32, named_groups : Set(String)) : Nil
        raise re_error("missing <") unless match('<')
        name = getuntil('>', "group name")

        if name.chars.all?(&.ascii_number?)
          # \g<007> is group 7 too (and \g<0> the whole match) - real
          # parses the digits as an int, leading zeros and all.
          significant = name.lstrip('0')
          value = if significant.empty?
                    0_i64
                  elsif significant.size > 10
                    MAX_GROUPS
                  else
                    significant.to_i64
                  end
          raise re_error("invalid group reference #{significant}", name.size + 1) if value >= MAX_GROUPS
          raise re_error("invalid group reference #{value}", name.size + 1) if value > groups
          text << '\\' << value
          return
        end

        unless identifier?(name)
          raise re_error("bad character in group name '#{name}'", name.size + 1)
        end
        unless named_groups.includes?(name)
          raise CrashError.new("unknown group name '#{name}'")
        end
        text << "\\k<" << name << '>'
      end

      # Whether the pending token is this one-character class's member.
      private def digit?(set : String) : Bool
        !!token.try { |current| current.size == 1 && set.includes?(current[0]) }
      end

      # str.isidentifier(), as far as a group name can exercise it: no
      # leading digit, letters/digits/underscores only. Every non-ASCII
      # character counts as a letter here - Crystal has no Unicode
      # category predicates, and the only cases this decides are exotic
      # group names like `\g<é>`, which real takes to the group-name
      # lookup (and this too) rather than to the "bad character" error.
      private def identifier?(name : String) : Bool
        return false if name.empty?
        name.each_char.with_index do |char, index|
          letter = char.ascii_letter? || !char.ascii?
          digit = char.ascii_number?
          return false unless letter || digit || char == '_'
          return false if index.zero? && digit
        end
        true
      end
    end

    # Python's errors="surrogateescape" text<->bytes round trip, for the
    # codecs this engine reads as raw bytes (the UTF-8/ASCII family, and
    # any codec iconv cannot convert). Each byte that is not part of a
    # valid UTF-8 sequence becomes one character - Python maps it to
    # U+DC80..U+DCFF, but PCRE2 aborts a match whose subject contains
    # raw surrogate codepoints, so the twin used here is the
    # private-use codepoint U+F780+(byte-0x80): one undecodable byte is
    # one character to the regex either way (`.` matches it, counts line
    # up identically), and encode() restores the exact original bytes on
    # write. The twin collision is the one Python itself carries: a
    # file legitimately containing the mapped codepoint round-trips
    # wrong under real Ansible too (its U+DC80..U+DCFF), just in a
    # different range.
    private module SurrogateText
      extend self

      def decode(raw : String) : String
        bytes = raw.to_slice
        String.build do |buffer|
          i = 0
          size = bytes.size
          while i < size
            if len = utf8_sequence_length(bytes[i])
              if i + len <= size && valid_continuation?(bytes, i, len)
                buffer.write(bytes[i, len])
                i += len
                next
              end
            end
            buffer << (0xF780 + bytes[i] - 0x80).chr
            i += 1
          end
        end
      end

      def encode(content : String) : Bytes
        output = Bytes.new(content.bytesize)
        w = 0
        content.each_char do |char|
          codepoint = char.ord
          if codepoint >= 0xF780 && codepoint <= 0xF7FF
            output[w] = (0x80 + codepoint - 0xF780).to_u8
            w += 1
          else
            char.bytes.each do |byte|
              output[w] = byte
              w += 1
            end
          end
        end
        output[0, w]
      end

      # Bytes in the UTF-8 sequence this lead byte starts, or nil when
      # it cannot start one. Strict UTF-8, exactly as CPython's decoder
      # validates: no overlong forms, no surrogates, max U+10FFFF - a
      # rejected byte is resurrogated individually (CPython resyncs one
      # byte at a time, so an overlong sequence becomes three twins).
      private def utf8_sequence_length(lead : UInt8) : Int32?
        if lead <= 0x7F
          1
        elsif lead >= 0xC2 && lead <= 0xDF
          2
        elsif lead >= 0xE0 && lead <= 0xEF
          3
        elsif lead >= 0xF0 && lead <= 0xF4
          4
        end
      end

      private def valid_continuation?(bytes : Bytes, start : Int32, len : Int32) : Bool
        return true if len == 1
        b1 = bytes[start + 1]
        b2 = bytes[start + 2]?
        case len
        when 2
          b1.in?(0x80..0xBF)
        when 3
          second_ok = case bytes[start]
                      when 0xE0 then b1.in?(0xA0..0xBF)
                      when 0xED then b1.in?(0x80..0x9F)
                      else           b1.in?(0x80..0xBF)
                      end
          second_ok && !!b2.try(&.in?(0x80..0xBF))
        else
          second_ok = case bytes[start]
                      when 0xF0 then b1.in?(0x90..0xBF)
                      when 0xF4 then b1.in?(0x80..0x8F)
                      else           b1.in?(0x80..0xBF)
                      end
          second_ok && !!b2.try(&.in?(0x80..0xBF)) &&
            !!bytes[start + 3]?.try(&.in?(0x80..0xBF))
        end
      end
    end

    # A left-to-right scan of a Python `re` pattern that catches the
    # error classes PCRE2 does not reproduce, worded and positioned
    # exactly as re._parser raises them (all real-verified against
    # Python 3.13, whose re backs ansible-core 2.19.11):
    #
    # - extensions Python rejects but PCRE2 accepts, most importantly
    #   the PCRE group-name spellings `(?<name>...)` / `(?'name'...)`
    #   (Python only takes (?P<name>...)), plus (?R)/(?&)/(?|/(?C)/(?{/
    #   (?1 etc. - "unknown extension ?<X at position N", where N is the
    #   index of the '?', or "unexpected end of pattern at position N"
    #   when the pattern ends inside the extension;
    # - the inline-flag section rules ("missing flag", "missing -, : or
    #   )") - Python's semantic flag checks (L-with-str etc.) stay
    #   unchecked;
    # - escapes Python rejects but PCRE2 accepts (\e, \z, \K, \h, \G,
    #   \C, \c, \o, \p, \Q, \x{...} - "bad escape \X at position N"),
    #   with context-dependent letters: Python allows \A/\B/\Z/\g only
    #   outside a character class;
    # - escape forms Python accepts but PCRE2 rejects (\uXXXX,
    #   \Uhhhhhhhh), rewritten to PCRE2's \x{...} so the compiled
    #   pattern means the same thing to both engines, and malformed
    #   spellings reported ("incomplete escape \u12 at position 0").
    #
    # \N{name} is left to PCRE2 (which rejects it): resolving Unicode
    # character names here is out of scope, so such patterns fail with
    # PCRE2's wording where real fails with "undefined character name".
    # Also unchecked: \8/\9 group-reference semantics, class ranges over
    # escapes, (?P=name) resolution, global-flags placement - all left
    # to PCRE2 or absent by design.
    private module PythonPattern
      # The scan result: the PCRE2-ready pattern, the first Python-re
      # error the scan can state exactly (nil when none), and the two
      # positions python_pcre_error needs when PCRE2 itself rejects the
      # pattern: the innermost unterminated '(' and the '[' of an
      # unterminated character class, both in ORIGINAL pattern
      # coordinates. Each \u/\U rewrite is remembered as {output char
      # index, output length, source char index} so PCRE2 error
      # positions can be mapped back through it.
      record Scan, translated : String, error : String?,
        unclosed_paren : Int32?, open_class_start : Int32?,
        rewrites : Array({Int32, Int32, Int32})?

      def self.scan(pattern : String) : Scan
        chars = pattern.chars
        size = chars.size
        builder = String::Builder.new
        builder_chars = 0
        rewrites : Array({Int32, Int32, Int32})? = nil
        paren_stack = [] of Int32
        class_start = 0
        in_class = false
        error : String? = nil
        i = 0
        while i < size && error.nil?
          c = chars[i]
          if in_class
            case c
            when '\\'
              consumed, err, replacement = check_escape(chars, i, true)
              if err
                error = err
                break
              end
              if rep = replacement
                rewrites ||= [] of {Int32, Int32, Int32}
                rewrites.not_nil! << {builder_chars, rep.size, i}
                builder << rep
                builder_chars += rep.size
              else
                chars[i, consumed].each do |source_char|
                  builder << source_char
                  builder_chars += 1
                end
              end
              i += consumed
            when ']'
              in_class = false
              builder << c
              builder_chars += 1
              i += 1
            else
              builder << c
              builder_chars += 1
              i += 1
            end
            next
          end
          case c
          when '\\'
            consumed, err, replacement = check_escape(chars, i, false)
            if err
              error = err
              break
            end
            if rep = replacement
              rewrites ||= [] of {Int32, Int32, Int32}
              rewrites.not_nil! << {builder_chars, rep.size, i}
              builder << rep
              builder_chars += rep.size
            else
              chars[i, consumed].each do |source_char|
                builder << source_char
                builder_chars += 1
              end
            end
            i += consumed
          when '['
            in_class = true
            class_start = i
            # ']' as the first class member (after an optional ^) is
            # literal, exactly as Python's tokenizer treats it
            j = i + 1
            j += 1 if chars[j]? == '^'
            j += 1 if chars[j]? == ']'
            while i < j
              builder << chars[i]
              builder_chars += 1
              i += 1
            end
          when '('
            paren_stack << i
            if i + 1 < size && chars[i + 1] == '?'
              if err = check_extension(chars, i, size)
                error = err
                break
              end
              marker = chars[i + 2]
              if marker == '#'
                # comment: Python skips raw to its own ')' - which also
                # balances the '(' this scanner pushed, without ever
                # opening a group
                j = i + 3
                while j < size && chars[j] != ')'
                  j += 1
                end
                if j >= size
                  error = "missing ), unterminated comment at position #{paren_stack.last}"
                else
                  paren_stack.pop
                  while i <= j
                    builder << chars[i]
                    builder_chars += 1
                    i += 1
                  end
                  next
                end
              elsif marker.in?('i', 'L', 'm', 's', 'x', 'a', 'u', '-')
                error = check_flags(chars, i + 2, size)
              end
            end
            unless error
              builder << c
              builder_chars += 1
              i += 1
            end
          when ')'
            paren_stack.pop?
            builder << c
            builder_chars += 1
            i += 1
          else
            builder << c
            builder_chars += 1
            i += 1
          end
        end
        if error
          return Scan.new(pattern, error, nil, nil, nil)
        end
        Scan.new(builder.to_s, nil, paren_stack.last?, in_class ? class_start : nil, rewrites)
      end

      # After '(': Python's extension dispatch, exactly as
      # re._parser._parse orders it. The accepted set is Python 3.13's
      # own: P/:/#/=/!/< (only with =/!)/(/(>/atomic and the inline
      # flags; everything else is an re.error whose position is the
      # index of the '?'.
      private def self.check_extension(chars : Array(Char), i : Int32, size : Int32) : String?
        if i + 2 >= size
          return "unexpected end of pattern at position #{size}"
        end
        case chars[i + 2]
        when 'P'
          if i + 3 >= size
            return "unexpected end of pattern at position #{size}"
          end
          following = chars[i + 3]
          unless following == '<' || following == '='
            return "unknown extension ?P#{following} at position #{i + 1}"
          end
        when '<'
          if i + 3 >= size
            return "unexpected end of pattern at position #{size}"
          end
          following = chars[i + 3]
          unless following == '=' || following == '!'
            return "unknown extension ?<#{following} at position #{i + 1}"
          end
        when ':', '#', '=', '!', '(', '>'
          nil
        when 'i', 'L', 'm', 's', 'x', 'a', 'u', '-'
          check_flags(chars, i + 2, size)
        else
          "unknown extension ?#{chars[i + 2]} at position #{i + 1}"
        end
      end

      # The inline-flag section between "(?" and its ':' or ')'
      # terminator: flag chars i/L/m/s/x/a/u with optional '-' groups -
      # Python's "missing flag" fires when a '-' (or the section) meets
      # a non-flag, and "missing -, : or )" when the section never
      # terminates. (The semantic checks Python then applies - L with a
      # str pattern, a/u negation - stay unchecked.)
      private def self.check_flags(chars : Array(Char), start : Int32, size : Int32) : String?
        j = start
        after_minus = false
        while j < size
          cj = chars[j]
          if cj == '-'
            return "missing flag at position #{j}" if after_minus
            after_minus = true
          elsif "iLmsxua".includes?(cj)
            after_minus = false
          elsif cj == ':' || cj == ')'
            return "missing flag at position #{j}" if after_minus
            return nil
          else
            return "missing flag at position #{j}" if after_minus
            return "missing -, : or ) at position #{j}"
          end
          j += 1
        end
        "missing -, : or ) at position #{size}"
      end

      # The escape at chars[i] == '\\'. Returns {source chars consumed,
      # error?, replacement?} - a replacement only for the two forms
      # Python accepts and PCRE2 does not (\uXXXX, \Uhhhhhhhh), spelled
      # as PCRE2's \x{...}. Positions are the index of the backslash,
      # as re._parser reports them.
      private def self.check_escape(chars : Array(Char), i : Int32, in_class : Bool) : {Int32, String?, String?}
        size = chars.size
        if i + 1 >= size
          return {1, "bad escape (end of pattern) at position #{i}", nil}
        end
        c = chars[i + 1]
        # \0-\7 are octal escapes/group references in both engines; \8
        # and \9 differ semantically (Python counts groups, PCRE2
        # errors) and stay with PCRE2.
        return {2, nil, nil} if c.ascii_number?
        unless c.ascii_letter?
          return {2, nil, nil}
        end
        case c
        when 'a', 'b', 'f', 'n', 'r', 't', 'v', 'd', 'D', 's', 'S', 'w', 'W'
          {2, nil, nil}
        when 'x'
          hex = hex_run(chars, i + 2, 2)
          if hex.size == 2
            {4, nil, nil}
          else
            {2, "incomplete escape \\x#{hex} at position #{i}", nil}
          end
        when 'u'
          hex = hex_run(chars, i + 2, 4)
          if hex.size == 4
            {6, nil, "\\x{#{hex}}"}
          else
            {2, "incomplete escape \\u#{hex} at position #{i}", nil}
          end
        when 'U'
          hex = hex_run(chars, i + 2, 8)
          if hex.size == 8
            {10, nil, "\\x{#{hex}}"}
          else
            {2, "incomplete escape \\U#{hex} at position #{i}", nil}
          end
        when 'N'
          if i + 2 < size && chars[i + 2] == '{'
            {2, nil, nil}
          else
            {2, "missing { at position #{i + 2}", nil}
          end
        when 'g'
          if !in_class && i + 2 < size && (chars[i + 2] == '<' || chars[i + 2] == '\'')
            {2, nil, nil}
          else
            {2, "bad escape \\g at position #{i}", nil}
          end
        when 'A', 'B', 'Z'
          if in_class
            {2, "bad escape \\#{c} at position #{i}", nil}
          else
            {2, nil, nil}
          end
        else
          {2, "bad escape \\#{c} at position #{i}", nil}
        end
      end

      private def self.hex_run(chars : Array(Char), from : Int32, limit : Int32) : String
        result = String::Builder.new
        j = from
        while j < chars.size && result.bytesize < limit && "0123456789abcdefABCDEF".includes?(chars[j])
          result << chars[j]
          j += 1
        end
        result.to_s
      end

      # Translated-pattern char index -> original-pattern char index,
      # through the \u/\U rewrites (each maps its whole output span to
      # the source index of its backslash).
      def self.source_index(scan : Scan, translated_char_index : Int32) : Int32
        index = translated_char_index
        if rewrites = scan.rewrites
          rewrites.each do |out_start, out_len, src|
            break if index < out_start
            return src if index < out_start + out_len
            index -= out_len - 1
          end
        end
        index
      end

      # Whether the '}' at chars[close] closes a real {m,n}/ quantifier
      # (used to tell Python's "multiple repeat" from "nothing to
      # repeat" when PCRE2 reports an unusable quantifier after a
      # brace).
      def self.quantifier_brace?(chars : Array(Char), close : Int32) : Bool
        j = close - 1
        seen_digit = false
        while j >= 0 && chars[j].ascii_number?
          seen_digit = true
          j -= 1
        end
        if j >= 0 && chars[j] == ','
          j -= 1
          while j >= 0 && chars[j].ascii_number?
            seen_digit = true
            j -= 1
          end
        end
        j >= 0 && seen_digit && chars[j] == '{' && !(j > 0 && chars[j - 1] == '\\')
      end
    end

    # Applies mode if given; returns whether it changed. owner/group would
    # require resolving a name to uid/gid (getpwnam), which is only
    # meaningful for the local user of a local connection - the role's
    # replace tasks (os_hardening's yum gpgcheck) only request mode.
    private def apply_attributes(path : String) : Bool
      before = File.info?(path, follow_symlinks: false)

      mode = @params["mode"]?
      if mode
        begin
          # copy.cr's own mode convention: any all-digit string parses as
          # octal (leading zero or not); a symbolic mode (u+x) shells to a
          # real `chmod`.
          if mode =~ /\A0?[0-7]{3,4}\z/
            File.chmod(path, mode.to_i(8))
          else
            Process.run("chmod", [mode, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
          end
        rescue File::Error
          # Mode setting failed, continue anyway
        end
      end

      uid = -1
      gid = -1

      # A present owner:/group: value (explicit empty string included)
      # is always resolved - and an unresolvable name fails the task
      # like real Ansible's basic.py (round900811 kilip.chezmoi) -
      # instead of the old `&&`-short-circuit that silently skipped the
      # chown whenever the lookup came back empty.
      if owner = @params["owner"]?
        uid = resolve_owner_uid(owner)
      end

      if group = @params["group"]?
        gid = resolve_group_gid(group)
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      after = File.info?(path, follow_symlinks: false)
      return false unless before && after
      before.permissions != after.permissions ||
        before.owner_id != after.owner_id ||
        before.group_id != after.group_id
    rescue File::Error
      # A chown/chmod failure (e.g. not running as root/owner) shouldn't
      # fail the whole task - matches copy.cr's own identical rescue.
      false
    end

    # Backup of the original file before any write - lineinfile.cr's own
    # write_backup convention (same timestamped name shape), so every
    # file-editing module in this codebase reports backup_file the same
    # way.
    private def write_backup(path : String) : String
      # backup_local stamps LOCAL time (same as copy/template/assemble).
      timestamp = Time.local.to_s("%Y-%m-%d@%H:%M:%S")
      backup_file = "#{path}.#{Process.pid}.#{timestamp}~"
      File.copy(path, backup_file)
      backup_file
    end

    # validate: support - mirrors lineinfile.cr/copy.cr's merged approach:
    # stage the new content in a temp file, run the validate: command
    # (with %s substituted by the staged temp path) against it, and only
    # on a zero exit move it into place. On validation failure the temp
    # file is discarded and the real file is left untouched.
    #
    # Returns nil on success, or a failed PluginResult.
    private def write_with_optional_validate(path : String, new_section : String, section_start : Int32, section_end : Int32, original_content : String, encoding : String?, surrogate : Bool) : PluginResult?
      validate_cmd = @params["validate"]?
      if validate_cmd && !validate_cmd.includes?("%s")
        return PluginResult.new(changed: false, failed: true, msg: "validate must contain %s: #{validate_cmd}")
      end

      new_content = original_content.byte_slice(0, section_start) + new_section +
                    original_content.byte_slice(section_end, original_content.bytesize - section_end)

      temp_file = File.join(File.dirname(path), ".krikri-playbook-replace-#{Random::Secure.hex(8)}.tmp")
      begin
        # SECURITY: created EMPTY at 0600 and settled to its final mode
        # (the task's numeric mode:, else the existing path's own mode -
        # replace only ever rewrites an existing file) BEFORE the new
        # content lands - see BasePlugin#create_staging_temp. The old
        # write-first shape held the bytes at 0644 & ~umask until the
        # mode preservation below ran after the write.
        # apply_task_mode: false - the task's numeric mode: must NOT be
        # settled onto the temp at creation, or apply_attributes below
        # sees no drift after the rename and the result msg loses real
        # replace.py's "and ownership, perms or SE linux context changed"
        # suffix (real's atomic_move preserves the DEST's mode, and
        # check_file_attrs runs after the write and detects the drift
        # itself - same reasoning as lineinfile's own apply_task_mode:
        # false, see staging_temp_mode's block comment).
        create_staging_temp(temp_file, staging_temp_mode(path, 0o644, apply_task_mode: false))
        # surrogateescape read: the content holds private-use twins for
        # the file's undecodable bytes, so encode() restores the exact
        # original bytes and the rewritten region's replacements land as
        # they were spelled - writing the string through iconv instead
        # would emit the twins as their own UTF-8 encodings and corrupt
        # the file.
        if surrogate
          File.write(temp_file, SurrogateText.encode(new_content), perm: 0o600)
        elsif encoding
          File.write(temp_file, new_content, encoding: encoding, perm: 0o600)
        else
          File.write(temp_file, new_content, perm: 0o600)
        end
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Failed to write temporary file: #{ex.message}")
      end

      if validate_cmd
        validation = validate_file(temp_file, validate_cmd)
        unless validation[:ok]
          File.delete(temp_file) if File.exists?(temp_file)
          return PluginResult.new(changed: false, failed: true, msg: "failed to validate: rc:#{validation[:rc]} error:#{validation[:output]}")
        end
      end

      # Preserve an existing dest's ownership (the mode is already
      # settled on the empty temp above; a rename would otherwise reset
      # ownership to the temp file's). Best-effort chown, same as
      # lineinfile.cr.
      if (info = File.info?(path, follow_symlinks: false))
        begin
          File.chown(temp_file, uid: info.owner_id.to_i, gid: info.group_id.to_i)
        rescue File::Error
          nil
        end
      end

      begin
        File.rename(temp_file, path)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        return PluginResult.new(changed: false, failed: true, msg: "Failed to move file to destination: #{ex.message}")
      end

      nil
    end

    # Runs the validate: command (with %s substituted by the staged
    # temp path) - identical to lineinfile.cr/copy.cr's own helpers.
    private def validate_file(path : String, validate_cmd : String) : NamedTuple(ok: Bool, rc: Int32, output: String)
      cmd = validate_cmd.gsub("%s", shell_single_quote(path))
      output = IO::Memory.new

      result = Process.run(
        "/bin/sh",
        ["-c", cmd],
        output: output,
        error: output
      )

      {ok: result.exit_code == 0, rc: result.exit_code, output: output.to_s.strip}
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ReplacePlugin.new(config)
plugin.run
