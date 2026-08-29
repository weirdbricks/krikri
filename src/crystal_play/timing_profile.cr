module CrystalPlay
  # OPUS_PERFORMANCE_IMPROVEMENTS.md item #0 - `--timing-profile`.
  #
  # Every other item in that document is an estimate until the run's
  # wall-clock time can actually be attributed to something. This is
  # the attribution: a process-wide set of named buckets, each holding
  # a call count and an accumulated duration, printed as a trailing
  # block after the PLAY RECAP when `--timing-profile` was passed.
  #
  # Off by default and, when off, `#measure` degrades to a bare `yield`
  # (it is a yielding method, so the compiler inlines the block) - no
  # Time.monotonic call, no Hash lookup, nothing. That matters because
  # the finest-grained bucket here wraps `VarSubstitutor#substitute`,
  # which a real role calls tens of thousands of times.
  #
  # ## Double counting, and how it is avoided
  #
  # Buckets nest: `SSHManager.upload` runs a `chmod` through
  # `SSHManager.exec`, `ConditionalEvaluator.evaluate` renders through
  # `VarSubstitutor#substitute`. Naively summing both would count the
  # inner time twice and make the percentages meaningless.
  #
  # So every bucket declares a *group*. Entering a bucket while the
  # same group is already active on this fiber attributes no additional
  # time (and no additional call) - the outermost measurement in a
  # group owns the whole span. Buckets that deliberately want to report
  # a slice *of* another bucket (the local `ssh` process spawn inside
  # an ssh exec, say) simply use a different group, and are printed
  # indented as "nested detail, already included above".
  #
  # ## Fibers
  #
  # The re-entrancy guard is keyed per *fiber*, not globally: with
  # `--forks > 1`, `run_task_for_hosts_in_parallel` has one fiber per
  # host, and host B entering `transport` while host A is parked inside
  # it is genuine concurrency, not re-entrancy. The flip side is that
  # concurrent hosts' spans overlap in wall-clock terms, so bucket
  # totals can legitimately sum to more than the run's wall clock. The
  # report says so rather than pretending otherwise; `--forks 1` gives
  # a strictly additive profile.
  module TimingProfile
    @@enabled = false
    @@run_start = Time.monotonic
    @@counts = Hash(String, Int64).new(0_i64)
    @@nanos = Hash(String, Int64).new(0_i64)
    @@depth = Hash({UInt64, String}, Int32).new(0)

    def self.enabled? : Bool
      @@enabled
    end

    # Called from the CLI when `--timing-profile` is given. Also
    # (re)starts the wall clock, so the denominator is "time since the
    # flags were parsed" rather than "since the process image loaded".
    def self.enable : Nil
      @@enabled = true
      reset
    end

    # Spec-only counterpart to #enable - a run never turns profiling
    # back off, but a spec measuring the disabled path has to.
    def self.disable : Nil
      @@enabled = false
      reset
    end

    def self.reset : Nil
      @@counts.clear
      @@nanos.clear
      @@depth.clear
      @@run_start = Time.monotonic
    end

    def self.wall : Time::Span
      Time.monotonic - @@run_start
    end

    def self.count(bucket : String) : Int64
      @@counts[bucket]
    end

    def self.nanos(bucket : String) : Int64
      @@nanos[bucket]
    end

    # Times *bucket* around the block. See the class comment for what
    # *group* does; it defaults to the bucket's own name, which is the
    # right choice for any bucket that cannot contain another one.
    def self.measure(bucket : String, group : String = bucket, &)
      return yield unless @@enabled

      key = {Fiber.current.object_id, group}
      if @@depth[key] > 0
        @@depth[key] += 1
        begin
          return yield
        ensure
          @@depth[key] -= 1
        end
      end

      @@depth[key] = 1
      started = Time.monotonic
      begin
        yield
      ensure
        @@depth.delete(key)
        @@counts[bucket] += 1
        @@nanos[bucket] += (Time.monotonic - started).total_nanoseconds.to_i64
      end
    end

    # For a span that cannot be expressed as a block (the caller
    # already holds a start and an end).
    def self.record_span(bucket : String, elapsed : Time::Span) : Nil
      return unless @@enabled
      @@counts[bucket] += 1
      @@nanos[bucket] += elapsed.total_nanoseconds.to_i64
    end

    # {bucket key, label, indent}. `indent: 1` means "this is a slice
    # of the line above it and is NOT part of the section's own total".
    record Row, key : String, label : String, indent : Int32 = 0

    PHASE_ROWS = [
      Row.new("parse.playbook", "playbook + role parse"),
      Row.new("parse.inventory", "inventory parse"),
      Row.new("upload.plugins", "plugin upload / staging"),
      Row.new("execute", "task execution"),
      Row.new("execute.facts", "fact gathering", 1),
    ]

    # Only these four are non-overlapping and together are meant to
    # cover the run; "unaccounted" below is the wall clock minus their
    # sum (CLI startup, option parsing, recap rendering, and anything
    # else not on a measured path).
    PHASE_TOTAL_KEYS = ["parse.playbook", "parse.inventory", "upload.plugins", "execute"]

    TRANSPORT_ROWS = [
      Row.new("transport.ssh_exec", "ssh exec (fork + wire + remote)"),
      Row.new("transport.ssh_script", "ssh exec_script (batched / one-shot)"),
      Row.new("transport.ssh_spawn", "local ssh process spawn", 1),
      Row.new("transport.daemon_send", "daemon request (pipe round trip)"),
      Row.new("transport.daemon_spawn", "daemon start (ssh + remote exec)", 1),
      Row.new("transport.scp_upload", "scp upload"),
      Row.new("transport.scp_download", "scp download"),
      Row.new("transport.rsync", "rsync upload"),
      Row.new("transport.local_exec", "local plugin exec (no ssh)"),
    ]

    CONTROLLER_ROWS = [
      Row.new("controller.templating", "templating / substitution"),
      Row.new("controller.conditionals", "conditional evaluation"),
      Row.new("controller.crinja", "crinja render", 1),
      Row.new("display.result", "result display"),
    ]

    def self.report(io : IO = STDOUT) : Nil
      return unless @@enabled

      total = wall
      io.puts "=" * 70
      io.puts "TIMING PROFILE"
      io.puts "=" * 70
      io.puts "wall clock: #{format_span(total)}"
      io.puts "indented rows are a slice of the row above and are already counted in it."
      io.puts "with --forks > 1 concurrent hosts overlap, so totals can exceed wall clock."
      io.puts ""

      emit_section(io, "phases", PHASE_ROWS, total)

      accounted = PHASE_TOTAL_KEYS.sum { |key| @@nanos[key] }
      unaccounted = total.total_nanoseconds.to_i64 - accounted
      io.puts format_row("  unaccounted", nil, unaccounted, total)
      io.puts ""

      emit_section(io, "transport (nested inside task execution)", TRANSPORT_ROWS, total)
      io.puts ""
      emit_section(io, "controller-side (nested inside task execution)", CONTROLLER_ROWS, total)
    end

    private def self.emit_section(io : IO, title : String, rows : Array(Row), total : Time::Span) : Nil
      io.puts "#{title}:"
      printed = false
      rows.each do |row|
        next if @@counts[row.key] == 0
        printed = true
        label = "  " + ("  " * row.indent) + (row.indent > 0 ? "└ " : "") + row.label
        io.puts format_row(label, @@counts[row.key], @@nanos[row.key], total)
      end
      io.puts "  (nothing measured)" unless printed
    end

    private def self.format_row(label : String, count : Int64?, nanos : Int64, total : Time::Span) : String
      pct = total.total_nanoseconds > 0 ? (nanos / total.total_nanoseconds) * 100.0 : 0.0
      calls = count ? count.to_s : ""
      "#{label.ljust(44)}#{calls.rjust(8)}#{format_nanos(nanos).rjust(11)}#{sprintf("%7.1f%%", pct)}"
    end

    private def self.format_nanos(nanos : Int64) : String
      sprintf("%.3fs", nanos / 1_000_000_000.0)
    end

    private def self.format_span(span : Time::Span) : String
      sprintf("%.3fs", span.total_seconds)
    end
  end
end
