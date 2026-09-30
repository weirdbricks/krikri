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
  # Real 2.19 semantics ported from ansible/plugins/action/pause.py:
  # - seconds/minutes are `{'type': int}`-validated BEFORE anything
  #   happens: float values truncate (1.5 -> 1), non-numerics fail the
  #   task (failed=True, no wait, no crash).
  # - a computed duration below 1 second is clamped up to 1 (so
  #   `minutes: 0` still waits ~1 second, and its elapsed-based stdout
  #   reads "Paused for 0.02 minutes", not "0.0").
  # - delta is the integer elapsed seconds; never `changed`; runs under
  #   check mode (verified, not assumed).
  # - with a duration, the action plugin WRITES to the console itself
  #   before waiting: "Pausing for <n> seconds" (plus " (output is
  #   hidden)" when echo: false), and - only when a prompt was given -
  #   a second line telling the user how to cut the wait short, which
  #   carries a trailing CR because real prints it as `display(msg + "\r")`
  #   on a TTY it never actually reaches with non-interactive stdin.
  #   A duration expressed in minutes prints the CONVERTED second count
  #   (`minutes: 1` -> "Pausing for 60 seconds"), not the minutes value.
  class PauseActionPlugin < ActionPlugin
    # Real's Display deduplicates warnings globally - the non-interactive
    # stdin warning fires once per run even across hosts/tasks.
    @@stdin_warning_shown = false

    # The console line real appends to a duration-gated pause so the user
    # knows a TTY-less run is just sleeping (pause.py's seconds branch).
    # Its trailing CR is real's, not ours.
    INTERRUPT_HINT = "(ctrl+C then 'C' = continue early, ctrl+C then 'A' = abort)\r"

    def execute : ActionResult
      seconds_param = @params["seconds"]?
      minutes_param = @params["minutes"]?

      if seconds_param && minutes_param
        return ActionResult.final(ActionResult.plugin_result_json(false, true, "parameters are mutually exclusive: minutes|seconds"))
      end

      # echo is read BEFORE real narrows it (`echo = seconds is None and
      # echo`), so it still decides the " (output is hidden)" note on a
      # duration-gated pause. It rides a str type, so the lenient
      # true-spellings all land here, not a native-bool check.
      echo = @params["echo"]? ? Krikri.lenient_boolean_true?(@params["echo"]?) : true
      echo_note = echo ? "" : " (output is hidden)"

      unit = "minutes"
      wait : Int64? = nil
      if seconds_param
        value = parse_int_arg(seconds_param, "seconds")
        return validation_failure("seconds") unless value
        wait = value
        unit = "seconds"
      elsif minutes_param
        value = parse_int_arg(minutes_param, "minutes")
        return validation_failure("minutes") unless value
        wait = value * 60
      end

      unless wait
        # Real's pause always waits for Enter when no duration is given;
        # with a non-interactive stdin, display.prompt_until raises
        # AnsiblePromptNoninteractive and the action warns and continues
        # immediately (pause.py's AnsiblePromptNoninteractive handler).
        # Verified vs 2.19.11: `pause: {}` with stdin from /dev/null
        # prints exactly this on stderr and the task is ok.
        unless @@stdin_warning_shown
          STDERR.puts "[WARNING]: Not waiting for response to prompt as stdin is not interactive".colorize(:yellow)
          @@stdin_warning_shown = true
        end
      end

      start = Time.local
      # Only a duration makes the prompt a "wait for N, interruptible" one.
      # The console lines are handed to ResultDisplay instead of written
      # here: real's action plugin writes them itself, so they always land
      # between the task's own output and this item's status line -
      # including per loop item, where krikri defers every item's display
      # to the end of the loop (executor_loops.cr's finish_looped_task)
      # and writing here would print every item's banner before the very
      # first item's "ok:".
      console_lines : Array(JSON::Any)? = nil
      if requested = wait
        # Real clamps the CONVERTED second count up to 1 before both the
        # console line and the sleep, so `seconds: 0`, `minutes: 0` and any
        # negative all announce and wait the same 1 second.
        clamped = requested < 1 ? 1_i64 : requested
        console = ["Pausing for #{clamped} seconds#{echo_note}"]
        # The interrupt hint is the PROMPT's slot, not an extra line: with
        # a prompt real prints it after the "Pausing for" line, and with
        # no prompt it REPLACES the prompt instead - which is never
        # written at all with non-interactive stdin.
        if prompt_given?
          console << INTERRUPT_HINT
        end
        console_lines = console.map { |line| JSON::Any.new(line) }
        sleep clamped.to_f
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
        "echo"       => JSON::Any.new(echo),
        "user_input" => JSON::Any.new(""),
      }
      # Engine-internal: the console lines never belong in real's pause
      # result dict, and the _ansible_ prefix is what keeps them out of
      # register: and of every LOOPED per-item results[] entry (both
      # strip the prefix).
      extra["_ansible_pause_console"] = JSON::Any.new(console_lines) if console_lines
      ActionResult.final(ActionResult.plugin_result_json(false, false, "", extra))
    end

    # Real's own `if new_module_args['prompt']` truthiness test on the
    # spec-converted prompt: absent, explicit None and an empty string all
    # take real's default "Press enter to continue" prompt (which then
    # becomes the interrupt hint instead of being printed).
    private def prompt_given? : Bool
      prompt = @params["prompt"]?
      return false if prompt.nil? || prompt == Krikri::NONE_SENTINEL
      Krikri.python_param_truthy?(prompt)
    end

    # Real validates seconds/minutes through the int CALLABLE, so what
    # arrives already passed that check upstream and this only has to
    # recover the VALUE - the Python-truthy cases the demoted wire text
    # alone cannot express: a natively-typed `seconds: true` is 1 and
    # `seconds: false` is 0 (bool IS an int in Python, and both end up
    # clamped to the same 1-second wait), a native float truncates
    # (int(1.9) == 1), and a native int needs no parsing at all. A
    # quoted string that is not int-shaped ("1.5") is rejected by the
    # spec check before this plugin runs, so the float fallback here only
    # ever sees a genuinely integer-shaped value.
    private def parse_int_arg(value : String, name : String) : Int64?
      if native = Krikri.non_string_scalar(value)
        case raw = native.raw
        when Bool    then raw ? 1_i64 : 0_i64
        when Int64   then raw
        when Int32   then raw.to_i64
        when Float64 then raw.to_i64
        end
      else
        f = value.to_f?
        return nil unless f && f.finite?
        f.to_i64
      end
    end

    private def validation_failure(name : String) : ActionResult
      ActionResult.final(ActionResult.plugin_result_json(false, true, "argument '#{name}' of type int could not be converted to an int"))
    end

    private def format_time(time : Time) : String
      time.to_s("%Y-%m-%d %H:%M:%S.%6N")
    end
  end
end
