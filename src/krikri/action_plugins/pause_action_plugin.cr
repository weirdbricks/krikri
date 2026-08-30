require "json"
require "../base_action_plugin"

module Krikri
  # pause: (ansible.builtin.pause) as a controller-side action plugin -
  # ported verbatim from plugins/pause.cr (including the documented
  # scope cut: only the countdown form is implemented, no interactive
  # TTY prompt model). Sleeping here blocks this host's own execution
  # fiber via Crystal's cooperative scheduler, the same wall-clock delay
  # a subprocess sleep produced before, but without the subprocess (or,
  # for a remote host, the SSH round trip) that used to carry it out.
  # plugins/pause.cr is kept as a real, working binary for
  # `--async`/manual invocation.
  class PauseActionPlugin < ActionPlugin
    def execute : ActionResult
      seconds_param = @params["seconds"]?
      minutes_param = @params["minutes"]?

      if seconds_param && minutes_param
        return ActionResult.final(ActionResult.plugin_result_json(false, true, "parameters are mutually exclusive: minutes|seconds"))
      end

      start = Time.local
      duration, stdout = duration_and_message(seconds_param, minutes_param)
      sleep(duration.seconds) if duration > 0
      stop = Time.local

      extra = {
        "start"      => JSON::Any.new(format_time(start)),
        "stop"       => JSON::Any.new(format_time(stop)),
        "delta"      => JSON::Any.new((stop - start).total_seconds.to_i64),
        "stdout"     => JSON::Any.new(stdout),
        "stderr"     => JSON::Any.new(""),
        "rc"         => JSON::Any.new(0_i64),
        "echo"       => JSON::Any.new(true?(@params["echo"]?, default: true)),
        "user_input" => JSON::Any.new(""),
      }
      ActionResult.final(ActionResult.plugin_result_json(false, false, "", extra))
    end

    private def duration_and_message(seconds_param : String?, minutes_param : String?) : {Float64, String}
      if seconds_param
        value = seconds_param.to_f
        {value, "Paused for #{format_amount(value)} seconds"}
      elsif minutes_param
        value = minutes_param.to_f
        {value * 60, "Paused for #{format_amount(value)} minutes"}
      else
        {0.0, "Paused without an interactive prompt (not supported) - continuing immediately"}
      end
    end

    private def format_amount(value : Float64) : String
      (value.round(2)).to_s
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
