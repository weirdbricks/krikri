#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # pause plugin (ansible.builtin.pause) - waits, or (in real Ansible)
  # interactively prompts. crystal-ansible has no interactive TTY/prompt
  # model, so only the countdown form (`seconds:`/`minutes:`) is
  # implemented - the documented scope cut this entry itself called for.
  # A bare `pause:` with neither given would block on stdin in real
  # Ansible; since there's nothing to collect here, it's treated as an
  # instant no-op rather than hanging the playbook run forever.
  #
  # `seconds:` and `minutes:` are mutually exclusive in real Ansible
  # (verified against a real ansible-playbook run: passing both, even
  # `minutes: 0`, fails with "parameters are mutually exclusive:
  # minutes|seconds") - this entry's own original scoping ("minutes,
  # combined with seconds") had that wrong. Never `changed`, and (unlike
  # `uri`/`wait_for`/`fetch`) real Ansible's `pause` genuinely does run
  # under check mode - verified, not assumed - so this doesn't skip under
  # `check_mode:` either.
  class PausePlugin < BasePlugin
    def execute : PluginResult
      seconds_param = @params["seconds"]?
      minutes_param = @params["minutes"]?

      if seconds_param && minutes_param
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: minutes|seconds")
      end

      start = Time.local
      duration, stdout = duration_and_message(seconds_param, minutes_param)
      sleep(duration.seconds) if duration > 0
      stop = Time.local

      PluginResult.new(
        changed: false, failed: false, msg: "",
        start: format_time(start), stop: format_time(stop),
        delta: (stop - start).total_seconds.to_i,
        stdout: stdout, stderr: "", rc: 0,
        echo: true?(@params["echo"]?, default: true),
        user_input: ""
      )
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
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::PausePlugin.new(config)
plugin.run
