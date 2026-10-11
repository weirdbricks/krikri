module Krikri
  # Emulation of ansible-core's `oneline` stdout callback (2.19.11,
  # live-verified byte shapes) for krikri-playbook runs, enabled by
  # `ANSIBLE_STDOUT_CALLBACK=oneline` (or the `ansible.builtin.oneline`
  # FQCN) or the krikri-only `-o` / `--one-line` / `--krikri-oneline`
  # flags.
  #
  # What changes under oneline - the stdout callback REPLACES the default
  # callback's whole output surface:
  # - No banners at all (PLAY, PLAYBOOK, TASK, RUNNING HANDLER, PLAY
  #   RECAP) and no PLAY RECAP block.
  # - One line per host result instead of the ok:/changed:/fatal: shapes.
  # - Looped tasks print ONE aggregate line per host (the real callback
  #   ignores the per-item events and renders the loop's aggregate
  #   result), skipped loops included: a loop that executes nothing is a
  #   single `host | SKIPPED` line.
  # - `...ignoring`, `fatal: [...]` blocks and the [ERROR] task-error
  #   blocks do not print (they are default-callback output).
  # - stderr output (warnings, deprecations) is callback-independent and
  #   keeps printing, including oneline's own startup deprecation.
  #
  # Line shapes (live-captured from 2.19.11):
  # - `host | CHANGED | rc=0 | (stdout) hi` - command-family results
  #   (MODULE_NO_JSON: command, shell, raw, win_command, win_shell; an
  #   async job id forces the dict shape instead). Empty stdout leaves a
  #   trailing space; embedded newlines render as literal `\n`/`\r`;
  #   a non-empty stderr appends ` (stderr) ...` (no pipe).
  # - `host | SUCCESS => {json}` / `host | CHANGED => {json}` - dict
  #   results, dumped sorted; compact (indent=0) unless the result is
  #   tagged `_ansible_verbose_always` (debug/assert), which yields the
  #   4-space-indent dump with newlines stripped.
  # - `host | FAILED | rc=2 | (stdout) ...` + `host | FAILED! => {json}` -
  #   a failed command-family result prints BOTH lines (2.19 tags module
  #   failures with an exception); other failures print
  #   `An exception occurred during task execution. To see the full
  #   traceback, use -vvv. The error was: <last exception line>` first,
  #   then the FAILED! dump. An exception-less failed result still prints
  #   the exception line with the `(traceback unavailable)` placeholder
  #   2.19 synthesizes.
  # - `host | SKIPPED`, `host | UNREACHABLE!: <msg>`.
  #
  # The per-result rendering half lives in task_executor/result_display.cr
  # (it needs the ad-hoc dump machinery that file owns); this half is the
  # dependency-free state and line-shape core, so the banner funnel can
  # check `Oneline.enabled?` without dragging the display layer in.
  module Oneline
    # Byte-parity with 2.19.11: the oneline callback deprecates itself at
    # load time. This is 2.19 behavior parity, not a krikri deprecation.
    DEPRECATION_TEXT = "The oneline callback plugin is deprecated. This feature will be removed from ansible-core version 2.23."

    @@enabled = false

    def self.enable : Nil
      @@enabled = true
    end

    def self.enabled? : Bool
      @@enabled
    end

    # Shared by every `skipping: [host]` print site: under oneline the
    # whole suffix machinery collapses to the bare status line.
    def self.skip_line(host_name : String, suffix : String = "") : String
      enabled? ? "#{host_name} | SKIPPED" : "skipping: [#{host_name}]#{suffix}"
    end

    # ansible-core's C.MODULE_NO_JSON membership, by short module name
    # (the FQCN's last segment - `ansible.builtin.command` and
    # `ansible.windows.win_command` both qualify).
    def self.command_module?(module_name : String?) : Bool
      return false unless module_name
      {"command", "shell", "raw", "win_command", "win_shell"}.includes?(module_name.split(".").last)
    end

    # The real callback's exception-branch line: the LAST line of the
    # (stripped) exception text after the fixed prefix. 2.19 tags every
    # module-failure result with an exception - `(traceback unavailable)`
    # when there is no real traceback.
    def self.exception_line(exception_text : String) : String
      stripped = exception_text.strip
      last_line = stripped.lines.last? || stripped
      "An exception occurred during task execution. To see the full traceback, use -vvv. The error was: #{last_line}"
    end

    # The real callback's `_command_generic_msg`: `host | caption |
    # rc=N | (stdout) X` with the escaped stdout, and ` (stderr) Y`
    # appended without a pipe when stderr is present and non-empty. A
    # result with no `rc` renders rc=-1 (Python's `result.get('rc', -1)`).
    def self.command_msg(host_name : String, caption : String, result : JSON::Any) : String
      stdout = (result["stdout"]?.try(&.as_s?) || "").gsub('\n', "\\n").gsub('\r', "\\r")
      line = "#{host_name} | #{caption} | rc=#{result["rc"]?.try(&.as_i?) || -1} | (stdout) #{stdout}"
      stderr = result["stderr"]?.try(&.as_s?) || ""
      stderr.empty? ? line : "#{line} (stderr) #{stderr.gsub('\n', "\\n").gsub('\r', "\\r")}"
    end
  end
end
