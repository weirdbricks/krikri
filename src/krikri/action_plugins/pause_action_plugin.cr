require "json"
require "../base_action_plugin"

module Krikri
  # pause: (ansible.builtin.pause) as a controller-side action plugin -
  # ported from plugins/pause.cr. Sleeping here blocks this host's own
  # execution fiber via Crystal's cooperative scheduler, the same
  # wall-clock delay a subprocess sleep produced before, but without the
  # subprocess (or, for a remote host, the SSH round trip) that used to
  # carry it out. plugins/pause.cr is kept as a real, working binary for
  # `--async`/manual invocation.
  #
  # krikri has no interactive TTY/prompt model, so it never blocks on
  # stdin - which matches real Ansible's own non-interactive behavior
  # (verified against ansible-core 2.14: with closed stdin and no
  # duration, real pause warns "Not waiting for response to prompt as
  # stdin is not interactive" and continues immediately, ok). The
  # prompt text is display-only in real Ansible: the result's stdout is
  # ALWAYS "Paused for X seconds|minutes" computed from the actual
  # elapsed wall-clock time (rounded to 2 decimals, minutes-unit divided
  # by 60), never the requested amount and never the prompt text.
  #
  # Real 2.14 semantics ported from ansible/plugins/action/pause.py:
  # - seconds/minutes are `{'type': int}`-validated BEFORE anything
  #   happens: float values truncate (1.5 -> 1), non-numerics fail the
  #   task (failed=True, no wait, no crash).
  # - a computed duration below 1 second is clamped up to 1 (so
  #   `minutes: 0` still waits ~1 second, and its elapsed-based stdout
  #   reads "Paused for 0.02 minutes", not "0.0").
  # - delta is the integer elapsed seconds; never `changed`; runs under
  #   check mode (verified, not assumed).
  class PauseActionPlugin < ActionPlugin
    def execute : ActionResult
      seconds_param = @params["seconds"]?
      minutes_param = @params["minutes"]?

      if seconds_param && minutes_param
        return ActionResult.final(ActionResult.plugin_result_json(false, true, "parameters are mutually exclusive: minutes|seconds"))
      end

      unit = "minutes"
      wait : Float64? = nil
      if seconds_param
        value = parse_int_arg(seconds_param, "seconds")
        return validation_failure("seconds") unless value
        wait = value.to_f
        unit = "seconds"
      elsif minutes_param
        value = parse_int_arg(minutes_param, "minutes")
        return validation_failure("minutes") unless value
        wait = value.to_f * 60
      end

      start = Time.local
      if w = wait
        sleep(w < 1 ? 1.0 : w)
      end
      stop = Time.local

      elapsed = (stop - start).total_seconds
      shown = unit == "minutes" ? (elapsed / 60).round(2) : elapsed.round(2)

      extra = {
        "start"      => JSON::Any.new(format_time(start)),
        "stop"       => JSON::Any.new(format_time(stop)),
        "delta"      => JSON::Any.new(elapsed.to_i64),
        "stdout"     => JSON::Any.new("Paused for #{shown} #{unit}"),
        "stderr"     => JSON::Any.new(""),
        "rc"         => JSON::Any.new(0_i64),
        "echo"       => JSON::Any.new(true?(@params["echo"]?, default: true)),
        "user_input" => JSON::Any.new(""),
      }
      ActionResult.final(ActionResult.plugin_result_json(false, false, "", extra))
    end

    # Real validates seconds/minutes as int: floats truncate toward zero
    # (Python int(1.5) == 1), anything non-numeric fails validation. The
    # param arrives stringified, so the YAML float 1.5 and the string
    # "1.5" are indistinguishable here and both truncate.
    private def parse_int_arg(value : String, name : String) : Int64?
      f = value.to_f?
      return nil unless f && f.finite?
      f.to_i64
    end

    private def validation_failure(name : String) : ActionResult
      ActionResult.final(ActionResult.plugin_result_json(false, true, "argument '#{name}' of type int could not be converted to an int"))
    end

    private def format_time(time : Time) : String
      time.to_s("%Y-%m-%d %H:%M:%S.%6N")
    end

    private def true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end
