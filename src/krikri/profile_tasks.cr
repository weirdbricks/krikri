module Krikri
  # Emulation of the `ansible.posix.profile_tasks` aggregate callback
  # (byte-shaped against ansible-core 2.19.11 + ansible.posix 2.1.0,
  # live-verified): a timestamp line under every TASK / RUNNING HANDLER
  # banner - `<weekday> <day> <month> <year>  <HH:MM:SS> <tz-offset>
  # (<previous task's wall clock>)       <running total> ******` - and a
  # TASKS RECAP block after PLAY RECAP listing every tracked task sorted
  # slowest first.
  #
  # The real callback's own shape source (profile_tasks.py):
  # - `filled(msg)`: `msg + " "` then `*` padding out to 80 columns
  #   TOTAL, then one trailing space; the timestamp line is therefore
  #   always exactly 80 columns wide regardless of the tty width (the
  #   `79` in filled() is a literal, not `Display.columns`).
  # - `tasktime()`: the parenthesized duration is the time elapsed since
  #   the PREVIOUS tasktime call (i.e. the previous task's wall clock,
  #   connection overhead included), the unpadded value is the running
  #   total since the module was imported (playbook start), separated by
  #   exactly seven spaces before `filled` adds its own.
  # - Duration format `H:MM:SS.mmm` - hours are NOT zero-padded.
  # - Timestamp format `"%A %d %B %Y  %H:%M:%S %z"` - two spaces between
  #   the year and the clock, English weekday/month names.
  # - TASKS RECAP: `Display.banner("TASKS RECAP")` (blank line + 80-wide
  #   banner), a tasktime line of its own, a full-width `=` rule, then
  #   one row per tracked task: `name ` padded with dashes to
  #   `Display.columns - 9` and ` X.XXs` right-aligned in 9 columns with
  #   dashes, sorted by elapsed duration descending (stable - ties keep
  #   first-seen order), capped at 20 rows (the callback's default
  #   `task_output_limit`).
  # - Handlers appear in the recap under their own names (live-verified),
  #   and looped tasks are one row total (one task, one entry).
  #
  # Deliberately not implemented (see KNOWN_MISSING.md): the callback's
  # own config surface (PROFILE_TASKS_TASK_OUTPUT_LIMIT,
  # PROFILE_TASKS_SORT_ORDER, PROFILE_TASKS_SUMMARY_ONLY) and the -vv+
  # per-row `task path:` line.
  module ProfileTasks
    # The real callback's default `task_output_limit`.
    RECAP_ROW_LIMIT = 20

    # Synthetic identity for the implicit Gathering Facts task - it is
    # not a Task object in this engine, but it still gets its own recap
    # row (live-verified).
    FACTS_TASK_IDENTITY = Reference.new

    private class TaskStat
      property name : String
      property elapsed_ms : Int64

      def initialize(@name, @elapsed_ms)
      end
    end

    @@enabled = false
    @@t0 = Time.local
    @@last_tick = Time.local
    @@current_key : UInt64?
    @@current_started = Time.local
    @@stats = Hash(UInt64, TaskStat).new

    def self.enable : Nil
      @@enabled = true
      # The real callback's `t0` is its module-import time - effectively
      # process start - so the first task's parenthesized duration
      # includes inventory/playbook parsing. Enabling happens at CLI/env
      # parse time here, the closest equivalent.
      @@t0 = @@last_tick = Time.local
    end

    def self.enabled? : Bool
      @@enabled
    end

    # One tracked task start: prints the timestamp line (under the banner
    # the caller has just printed - the caller owns banner placement, so
    # PLAY/PLAY RECAP banners stay unaffected), closes out the previous
    # task's duration, and opens the new one. Called once per task (not
    # per host), keyed by the Task object itself so `serial:` re-runs of
    # the same task accumulate into one row, matching the real callback's
    # per-UUID stats dict.
    def self.record_task_start(task, name : String) : Nil
      return unless @@enabled

      now = Time.local
      puts tasktime_line(now)

      if key = @@current_key
        @@stats[key]?.try do |stat|
          stat.elapsed_ms += (now - @@current_started).total_milliseconds.to_i64
        end
      end

      key = task.object_id
      @@stats[key] ||= TaskStat.new(name, 0)
      @@current_key = key
      @@current_started = now
    end

    # The TASKS RECAP block, printed once after PLAY RECAP (from the CLI
    # entrypoint's recap site). Emits its own banner lines directly
    # rather than through OutputBanner.banner: under the `oneline` stdout
    # callback the regular banners are suppressed, but the real
    # profile_tasks callback still prints its own TASKS RECAP banner
    # (live-verified: oneline + profile_tasks together).
    def self.print_recap : Nil
      return unless @@enabled

      now = Time.local
      puts ""
      puts "TASKS RECAP #{OutputBanner.stars("TASKS RECAP")}"
      puts tasktime_line(now)

      if key = @@current_key
        @@stats[key]?.try do |stat|
          stat.elapsed_ms += (now - @@current_started).total_milliseconds.to_i64
        end
      end
      @@current_key = nil

      # The real callback's `filled("", "=")`: a literal 79-char rule (not
      # Display.columns) plus filled()'s trailing space.
      puts "=" * 79 + " "

      # Stable descending sort: Python's sorted() keeps ties in insertion
      # order, so equal-duration tasks stay in first-seen order.
      rows = @@stats.values
      ranked = rows.map_with_index { |stat, idx| {stat, idx} }.to_a.sort_by { |pair| {-pair[0].elapsed_ms, pair[1]} }.map(&.[0])
      row_width = OutputBanner.columns + 1
      ranked.first(RECAP_ROW_LIMIT).each do |stat|
        left = "#{stat.name} ".ljust(row_width - 9, '-')
        value = " #{sprintf("%.2f", stat.elapsed_ms / 1000.0)}s"
        puts left + value.rjust(9, '-')
      end
    end

    # `filled(tasktime-msg, "*")` from the real callback: `msg + " "`,
    # `*` padding to a total width of 80, then one trailing space.
    private def self.tasktime_line(now : Time) : String
      elapsed_ms = (now - @@last_tick).total_milliseconds.to_i64
      total_ms = (now - @@t0).total_milliseconds.to_i64
      @@last_tick = now
      msg = "#{now.to_s("%A %d %B %Y  %H:%M:%S %z")} (#{seconds_to_str(elapsed_ms)})" + (" " * 7) + seconds_to_str(total_ms)
      filled(msg, '*')
    end

    private def self.filled(msg : String, fchar : Char) : String
      padded = "#{msg} "
      width = 79 - padded.size
      width = 3 if width < 3
      "#{padded}#{fchar.to_s * width} "
    end

    # The real callback's secondsToStr: `%d:%02d:%02d.%03d` - hours NOT
    # zero-padded.
    def self.seconds_to_str(total_ms : Int64) : String
      hours = total_ms // 3_600_000
      minutes = (total_ms // 60_000) % 60
      seconds = (total_ms // 1000) % 60
      millis = total_ms % 1000
      sprintf("%d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    end
  end
end
