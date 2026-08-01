module CrystalPlay
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
    end
  end
end
