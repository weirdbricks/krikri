module Krikri
  module PluginHelpers
    # CronTable - pure logic for managing a named entry inside a crontab-style
    # text file. Ansible's cron module identifies "its" entry by a comment
    # marker line immediately above the schedule line; this module renders
    # that two-line block and knows how to find/replace/remove it inside
    # arbitrary crontab text, entirely without I/O so it's unit-testable with
    # plain strings.
    module CronTable
      def self.marker(name : String) : String
        "#Ansible: #{name}"
      end

      # Renders the 5 schedule fields, or a @special_time shorthand that
      # overrides them (matching Ansible's special_time: reboot/daily/etc).
      def self.schedule(minute : String, hour : String, day : String, month : String, weekday : String, special_time : String?) : String
        return "@#{special_time}" if special_time
        "#{minute} #{hour} #{day} #{month} #{weekday}"
      end

      # Renders the entry line itself (schedule + optional user + job),
      # commented out with a leading '#' when disabled.
      def self.render_line(schedule : String, job : String, user : String?, disabled : Bool) : String
        fields = user ? "#{schedule} #{user} #{job}" : "#{schedule} #{job}"
        disabled ? "##{fields}" : fields
      end

      # Finds/replaces/removes the {marker, entry} block for `name` inside
      # `text`. Pass new_line: nil to remove the entry entirely (state:
      # absent, or a name that simply isn't there yet - a no-op). Returns
      # {new_text, changed}.
      def self.upsert(text : String, name : String, new_line : String?) : {String, Bool}
        marker_line = marker(name)
        lines = text.split("\n")
        lines.pop if lines.size > 0 && lines.last.empty?
        result = [] of String
        found = false
        i = 0

        while i < lines.size
          if lines[i].strip == marker_line
            found = true
            i += 2 # drop the marker line and the entry line beneath it
            if new_line
              result << marker_line
              result << new_line
            end
            next
          end

          result << lines[i]
          i += 1
        end

        if !found && new_line
          result << marker_line
          result << new_line
        end

        new_text = result.join("\n")
        new_text += "\n" unless new_text.empty?
        {new_text, new_text != normalize(text)}
      end

      # Trailing-newline-insensitive comparison baseline for `upsert`'s
      # changed? check, so re-running against a file that already ends with
      # exactly one newline isn't reported as a change.
      private def self.normalize(text : String) : String
        return "" if text.empty?
        text.rstrip("\n") + "\n"
      end

      # The NAME="value" line cron.py's env: yes path writes (decl is
      # always double-quoted, unlike cronvar's raw assignment).
      def self.env_decl(name : String, value : String) : String
        "#{name}=\"#{value}\""
      end

      # Finds/replaces/removes the ENVIRONMENT-VARIABLE assignment(s) for
      # `name` inside `text` - cron.py's env: yes code path, which differs
      # from CronVar/cronvar.py's: matching is a plain "^NAME=" line
      # prefix (not shlex tokens), a NEW variable defaults to the TOP of
      # the file, and insertafter/insertbefore name the variable to
      # position against (immediately after/before its first declaring
      # line). Pass decl: nil to remove (state: absent).
      #
      # Returns {new_text, changed, missing_insert_target}: the third
      # element is the insertafter/insertbefore variable name when it
      # doesn't exist - real cron.py treats that as a hard failure
      # ("Variable named '%s' not found.") rather than cronvar's silent
      # drop, and nothing is written in that case.
      def self.upsert_env(text : String, name : String, decl : String?, insert_after : String?, insert_before : String?) : {String, Bool, String?}
        lines = text.split("\n")
        lines.pop if lines.size > 0 && lines.last.empty?

        target = insert_after || insert_before
        if decl && target
          unless lines.any? { |line| env_line_for?(line, target) }
            # Real cron.py's add_env fails hard here and nothing is written.
            return {text, false, target}
          end
        end

        new_lines = apply_env(lines, name, decl, insert_after, insert_before)

        new_text = new_lines.join("\n")
        new_text += "\n" unless new_text.empty?
        {new_text, new_text != normalize(text), nil}
      end

      private def self.env_line_for?(line : String, var_name : String) : Bool
        line.starts_with?("#{var_name}=")
      end

      private def self.apply_env(lines : Array(String), name : String, decl : String?, insert_after : String?, insert_before : String?) : Array(String)
        idx = lines.index { |line| env_line_for?(line, name) }

        if decl.nil?
          return lines unless idx
          return lines.reject { |line| env_line_for?(line, name) }
        end

        if idx.nil?
          inserted = add_env_decl(lines, decl, insert_after, insert_before)
          return inserted if inserted
          # Missing insert target: caller surfaces the failure - report it
          # by leaving the text untouched (upsert_env's caller re-checks).
          return lines
        end

        return lines if lines[idx] == decl

        lines.map { |line| env_line_for?(line, name) ? decl : line }
      end

      # Real add_env: no insert option -> the new assignment goes to the
      # TOP of the file; otherwise it's spliced immediately after/before
      # the first line declaring the named variable. A missing target
      # variable is a hard failure upstream - signaled here by nil.
      private def self.add_env_decl(lines : Array(String), decl : String, insert_after : String?, insert_before : String?) : Array(String)?
        return [decl] + lines if !insert_after && !insert_before

        other = insert_after || insert_before
        return nil unless other
        idx = lines.index { |line| env_line_for?(line, other) }
        return nil unless idx

        result = lines.dup
        result.insert(insert_after ? idx + 1 : idx, decl)
        result
      end
    end
  end
end
