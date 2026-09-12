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
  # `prompt:` displays the given message while waiting. krikri has no
  # interactive TTY model, so it never blocks on stdin - which matches
  # real Ansible's own non-interactive behavior (verified against
  # ansible-core: with closed stdin and no duration, real pause warns
  # "Not waiting for response to prompt as stdin is not interactive" and
  # continues immediately, ok). With a duration, real Ansible's result
  # stdout stays "Paused for X <unit>" regardless of prompt (prompt text
  # is display-only), so krikri matches that too. With only a prompt and
  # no duration, the prompt text itself is the result's visible output.
  class PauseActionPlugin < ActionPlugin
    def execute : ActionResult
      seconds_param = @params["seconds"]?
      minutes_param = @params["minutes"]?
      prompt_param = @params["prompt"]?

      if seconds_param && minutes_param
        return ActionResult.final(ActionResult.plugin_result_json(false, true, "parameters are mutually exclusive: minutes|seconds"))
      end

      start = Time.local
      duration, stdout = duration_and_message(seconds_param, minutes_param, prompt_param)
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

    private def duration_and_message(seconds_param : String?, minutes_param : String?, prompt_param : String?) : {Float64, String}
      if seconds_param
        value = seconds_param.to_f
        {value, "Paused for #{format_amount(value)} seconds"}
      elsif minutes_param
        value = minutes_param.to_f
        {value * 60, "Paused for #{format_amount(value)} minutes"}
      elsif prompt_param
        {0.0, prompt_param}
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
