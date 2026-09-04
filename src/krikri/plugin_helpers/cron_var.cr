module Krikri
  module PluginHelpers
    # CronVar - pure logic for managing a named environment-variable
    # assignment (NAME=value line) inside crontab-style text, mirroring
    # ansible.builtin.cronvar's parse/update semantics. Entirely without
    # I/O so it's unit-testable with plain strings, same shape as
    # CronTable for the cron module.
    #
    # Detection mirrors real cronvar.py's shlex-based parse_for_var: a
    # line is a variable assignment iff its first whitespace-delimited
    # token (quotes group, '#' starts a comment, '=' is its own token)
    # is followed by a bare "=" token - so `MAILTO=root` and
    # `MAILTO = root` both match, but `FOOBAR=baz` does not match
    # name `FOO` (exact token match, case-sensitive), and crontab
    # schedule lines never parse as assignments (their second token is
    # a schedule field, never "=").
    module CronVar
      # Parses one line as a variable assignment. Returns {name, value}
      # or nil when the line isn't one (comment, schedule line, blank).
      # Unquoted spaces inside the value are swallowed exactly like real
      # cronvar.py's `"".join(lexer)` does ("bar baz" reads back as
      # "barbaz"); quoted spaces survive.
      def self.parse_var_line(line : String) : {String, String}?
        return nil if line.lstrip.empty? || line.lstrip.starts_with?('#')

        tokens = tokenize(line)
        return nil if tokens.size < 2 || tokens[1] != "="

        {tokens[0], tokens[2..].join}
      end

      # Every variable name currently assigned in the text, in file
      # order (real module's get_var_names, returned as the `vars` field).
      def self.var_names(text : String) : Array(String)
        text.split("\n").compact_map do |line|
          parse_var_line(line).try(&.[0])
        end
      end

      # The value of the first assignment named `name`, or nil.
      def self.find_variable(text : String, name : String) : String?
        text.split("\n").each do |line|
          parsed = parse_var_line(line)
          return parsed[1] if parsed && parsed[0] == name
        end
        nil
      end

      # Finds/replaces/removes the assignment named `name` inside `text`.
      # Pass new_value: nil to remove (state: absent). Returns
      # {new_text, changed}, with `changed` decided exactly like real
      # cronvar.py's main(): added (was absent), updated (value differs),
      # or removed (was present) - and NO change when it already matches.
      #
      # Known real-module quirk reproduced deliberately: inserting a NEW
      # variable with insertbefore/insertafter naming a variable that
      # doesn't exist silently drops the line (nothing is inserted) but
      # still reports changed: true - every subsequent run reports
      # changed again, forever, identically to real cronvar.
      def self.upsert(text : String, name : String, new_value : String?, insert_before : String? = nil, insert_after : String? = nil) : {String, Bool}
        old_value = find_variable(text, name)

        if new_value.nil?
          return {text, false} unless old_value

          kept = lines_of(text).reject do |line|
            parsed = parse_var_line(line)
            parsed && parsed[0] == name
          end
          {render(kept), true}
        else
          # Real main(): an empty value renders as the two-character
          # literal "" unless the variable already holds exactly "".
          new_value = "\"\"" if new_value.empty? && old_value != ""

          return {text, false} if old_value == new_value

          if old_value.nil?
            {render(add_variable(lines_of(text), name, new_value, insert_before, insert_after)), true}
          else
            {render(update_variable(lines_of(text), name, new_value)), true}
          end
        end
      end

      private def self.lines_of(text : String) : Array(String)
        lines = text.split("\n")
        lines.pop if lines.size > 0 && lines.last.empty?
        lines
      end

      # Real add_variable: no insert option -> the new assignment goes to
      # the TOP of the file; otherwise it's spliced before/after every
      # assignment named insertbefore/insertafter - and dropped entirely
      # when no such variable exists (see upsert's quirk note).
      private def self.add_variable(lines : Array(String), name : String, value : String, insert_before : String?, insert_after : String?) : Array(String)
        return ["#{name}=#{value}"] + lines if !insert_before && !insert_after

        result = [] of String
        lines.each do |line|
          parsed = parse_var_line(line)
          if parsed
            if parsed[0] == insert_before
              result << "#{name}=#{value}"
              result << line
              next
            elsif parsed[0] == insert_after
              result << line
              result << "#{name}=#{value}"
              next
            end
          end
          result << line
        end
        result
      end

      # Real update_variable: rewrites every assignment named `name` in
      # place (first-match-wins only applies to the changed? decision).
      private def self.update_variable(lines : Array(String), name : String, value : String) : Array(String)
        lines.map do |line|
          parsed = parse_var_line(line)
          if parsed && parsed[0] == name
            "#{name}=#{value}"
          else
            line
          end
        end
      end

      # Real render(): single joined block with exactly one trailing
      # newline.
      private def self.render(lines : Array(String)) : String
        joined = lines.join("\n")
        joined.empty? ? "" : joined.rstrip("\n") + "\n"
      end

      # Minimal shlex-shaped tokenizer: words are maximal runs of
      # non-whitespace chars excluding "=" and quotes; "=" is always its
      # own token; a quote character groups everything up to the matching
      # close quote into one token (so quoted spaces stay part of the
      # value).
      private def self.tokenize(line : String) : Array(String)
        tokens = [] of String
        word = String::Builder.new
        quote = nil

        flush = -> {
          unless word.empty?
            tokens << word.to_s
            word = String::Builder.new
          end
        }

        line.each_char do |char|
          if quote
            if char == quote
              tokens << word.to_s
              word = String::Builder.new
              quote = nil
            else
              word << char
            end
          elsif char == '\'' || char == '"'
            flush.call
            quote = char
          elsif char == '='
            flush.call
            tokens << "="
          elsif char.whitespace?
            flush.call
          else
            word << char
          end
        end
        flush.call

        tokens
      end
    end
  end
end
