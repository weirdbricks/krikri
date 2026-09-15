#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # pause plugin (ansible.builtin.pause) - waits, or (in real Ansible)
  # interactively prompts. krikri-playbook has no interactive TTY/prompt
  # model, so it never blocks on stdin - which matches real Ansible's
  # own non-interactive behavior (verified against ansible-core: with
  # closed stdin and no duration, real pause warns "Not waiting for
  # response to prompt as stdin is not interactive" and continues
  # immediately, ok). The prompt text is display-only in real Ansible:
  # the result's stdout is ALWAYS "Paused for X seconds|minutes"
  # computed from the actual elapsed wall-clock time (rounded to 2
  # decimals, minutes-unit divided by 60), never the requested amount
  # and never the prompt text.
  #
  # Real 2.14 semantics ported from ansible/plugins/action/pause.py:
  # - seconds/minutes are `{'type': int}`-validated BEFORE anything
  #   happens: float values truncate (1.5 -> 1), non-numerics fail the
  #   task (failed=True, no wait, no crash).
  # - a computed duration below 1 second is clamped up to 1 (so
  #   `minutes: 0` still waits ~1 second).
  # - `seconds:` and `minutes:` are mutually exclusive in real Ansible
  #   (verified against a real ansible-playbook run: passing both, even
  #   `minutes: 0`, fails with "parameters are mutually exclusive:
  #   minutes|seconds"). Never `changed`, and (unlike
  #   `uri`/`wait_for`/`fetch`) real Ansible's `pause` genuinely does
  #   run under check mode - verified, not assumed - so this doesn't
  #   skip under `check_mode:` either.
  class PausePlugin < BasePlugin
    def execute : PluginResult
      seconds_param = @params["seconds"]?
      minutes_param = @params["minutes"]?

      if seconds_param && minutes_param
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: minutes|seconds")
      end

      unit = "minutes"
      wait : Float64? = nil
      if seconds_param
        value = parse_int_arg(seconds_param, "seconds")
        return PluginResult.new(changed: false, failed: true, msg: "argument 'seconds' of type int could not be converted to an int") unless value
        wait = value.to_f
        unit = "seconds"
      elsif minutes_param
        value = parse_int_arg(minutes_param, "minutes")
        return PluginResult.new(changed: false, failed: true, msg: "argument 'minutes' of type int could not be converted to an int") unless value
        wait = value.to_f * 60
      end

      start = Time.local
      if w = wait
        sleep(w < 1 ? 1.0 : w)
      end
      stop = Time.local

      elapsed = (stop - start).total_seconds
      shown = unit == "minutes" ? (elapsed / 60).round(2) : elapsed.round(2)

      PluginResult.new(
        changed: false, failed: false, msg: "",
        start: format_time(start), stop: format_time(stop),
        delta: elapsed.to_i,
        stdout: "Paused for #{shown} #{unit}", stderr: "", rc: 0,
        echo: true?(@params["echo"]?, default: true),
        user_input: ""
      )
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

    private def format_time(time : Time) : String
      time.to_s("%Y-%m-%d %H:%M:%S.%6N")
    end

    private def true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PausePlugin.new(config)
plugin.run
