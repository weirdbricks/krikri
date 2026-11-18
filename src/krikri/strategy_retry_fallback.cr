module Krikri
  # A third-party strategy plugin is Python control-plane code this engine
  # cannot execute (see PlaybookParser.strategy_plugin_source), so a play
  # that names one runs as linear. That is harmless for a plugin that only
  # decorates the linear run, but the common case is a plugin that wraps
  # linear and RETRIES a failed task - and replacing it with plain linear
  # turns a transient failure into a first-attempt host failure, i.e. it
  # changes pass/fail (issue #1542).
  #
  # These settings are the built-in stand-in for that case: when a play's
  # strategy plugin had to be ignored, every task that wrote neither
  # `until:` nor `retries:` is retried on failure, the way ansible's
  # task_executor does once `retries` is set (its condition defaults to
  # `not utr.failed`). The attempt count and gap come from the retrying
  # plugin itself, which this engine cannot read, so the operator supplies
  # them once on the command line.
  #
  # Read ONLY for such a play, so an inherited environment can never
  # reshape a run whose strategy this engine does implement - and ansible
  # has no equivalent setting, which is why the names carry the krikri
  # prefix.
  module StrategyRetryFallback
    extend self

    RETRIES_ENV = "KRIKRI_STRATEGY_RETRIES"
    DELAY_ENV   = "KRIKRI_STRATEGY_RETRY_DELAY"

    # Ansible's own default gap between a retried task's attempts.
    DEFAULT_DELAY = 5

    struct Settings
      getter retries : Int32
      getter delay : Int32

      def initialize(@retries : Int32, @delay : Int32)
      end
    end

    # nil when the operator left the fallback unset (or set it to 0),
    # which keeps exactly the pre-#1542 behaviour.
    def settings : Settings?
      retries = int_value(RETRIES_ENV, 0)
      return nil if retries <= 0
      Settings.new(retries, int_value(DELAY_ENV, DEFAULT_DELAY))
    end

    # An unparseable value must stop the run: silently ignoring it would
    # leave the very pass/fail difference these settings exist to close.
    private def int_value(name : String, fallback : Int32) : Int32
      raw = ENV[name]?.try(&.strip)
      return fallback if raw.nil? || raw.empty?
      value = raw.to_i?
      unless value && value >= 0 && value <= Int32::MAX
        STDERR.puts "#{name} must be a non-negative integer, not '#{raw}'."
        exit 1
      end
      value.to_i32
    end
  end
end
