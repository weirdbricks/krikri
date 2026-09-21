#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

module Krikri
  # Shell Plugin - Execute shell commands with full shell features
  #
  # Parameters:
  #   cmd (required): Shell command to execute
  #   creates (optional): Skip if this file exists
  #   removes (optional): Skip if this file doesn't exist
  #   chdir (optional): Change directory before executing
  #   executable (optional): Shell to use (default: /bin/sh)
  #   argv (optional): Exact argument list, run through the shell
  #     element-wise-quoted and joined (real Ansible behavior)
  #   stdin (optional): Data piped to the command's stdin
  #   stdin_add_newline (optional): Append a newline to stdin: (default true)
  #   strip_empty_ends (optional): Rstrip trailing newlines from
  #     stdout:/stderr: (default true)
  #   check_mode (optional): Dry-run mode (always skips for shell)
  #
  # Examples:
  #   shell: echo "Hello" > /tmp/hello.txt
  #
  #   shell: find /var/log -name "*.log" | grep ERROR
  #   args:
  #     creates: /tmp/search-done
  #
  # stdout:/stderr: are rstripped of a trailing \r\n before being returned,
  # matching real Ansible's own AnsibleModule.run_command() - see
  # command.cr's own doc comment for how this was found (a real playbook
  # over real SSH comparing captured stdout against a constant).
  class ShellPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real shell module's own argspec - which IS command.py's (bookworm
    # ansible-core 2.14, the harness reference): the shell module is
    # command.py with _uses_shell=True, and its unsupported-parameters
    # message even names itself "ansible.legacy.command" when invoked as
    # ansible.builtin.shell (live-verified via the podman-diff
    # shell_edge_cases SH14 case). Note the list has NO cmd: and NO
    # expand_argument_vars:/warn: - cmd: is an ACTION-plugin-level param
    # the action plugin folds into _raw_params before the module ever
    # sees it (same seam as apt.cr's `use:` note), so it is accepted here
    # but not advertised; expand_argument_vars:/warn: simply don't exist
    # on 2.14 and fail like any other unknown param.
    private SHELL_SPEC = {
      "_raw_params"       => [] of String,
      "_uses_shell"       => [] of String,
      "argv"              => [] of String,
      "chdir"             => [] of String,
      "creates"           => [] of String,
      "executable"        => [] of String,
      "removes"           => [] of String,
      "stdin"             => [] of String,
      "stdin_add_newline" => [] of String,
      "strip_empty_ends"  => [] of String,
    }

    private SHELL_BOOL_PARAMS = %w[stdin_add_newline strip_empty_ends]

    property? check_mode : Bool
    property? diff_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
      @diff_mode = true?(@params["_ansible_diff"]?)
    end

    # See command.cr's copy for the full rationale: relative
    # creates:/removes: resolve against chdir: for the existence check,
    # absolute paths are used as-is. Unlike command.cr, shell.cr keeps
    # chdir raw for the `cd` itself (the shell expands ~), so the tilde
    # expansion happens here, on the check path only.
    private def resolve_against_chdir(path : String, chdir : String?) : String
      expanded = expand_tilde(path)
      return expanded if chdir.nil? || expanded.starts_with?('/')
      File.join(expand_tilde(chdir), expanded)
    end

    def execute : PluginResult
      # Real AnsibleModule setup validation (wording via the shared
      # helper, live-verified vs bookworm 2.14 via the podman-diff
      # shell_edge_cases SH14 case): any param outside the
      # shell/command argspec fails BEFORE anything runs - previously
      # only warn:/expand_argument_vars: were hand-rolled, and with
      # 2.19-era wordings ("(shell)" / "(ansible.legacy.shell)") that
      # don't match the 2.14 harness reference (which names the module
      # ansible.legacy.command with the 10-param supported list).
      unsupported = unsupported_param_keys(@params, SHELL_SPEC).reject { |k| k == "cmd" }
      unless unsupported.empty?
        return unsupported_params_error("ansible.legacy.command", unsupported, SHELL_SPEC)
      end

      SHELL_BOOL_PARAMS.each do |bool_param|
        next unless (raw = @params[bool_param]?)
        unless bool_convertible?(raw)
          return bool_type_error(bool_param, raw)
        end
      end

      # Same `warn:` rejection as command.cr - real ansible-core 2.19
      # rejects the removed param identically (message adjusted for the
      # shell module's own supported-parameter list; the tail after
      # "warn." matches ansible-core 2.19's shell argspec).
      # (The warn:/expand_argument_vars: rejections used to be hand-rolled
      # here with 2.19-era wordings; the general argspec check above
      # covers both under the 2.14 reference - see its comment.)

      # Get command (supports direct string, 'cmd' parameter, or 'argv')
      cmd = @params["_raw_params"]? || @params["cmd"]?
      argv = @params["argv"]?
      unless cmd || argv
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "no command given"
        )
      end

      # `argv:` works identically on shell to command's argv: - real
      # 2.19.4 shares the same underlying module implementation (the
      # shell module IS command.py with _uses_shell=True), where
      # `args = args or argv` picks the argv list and basic.py's
      # run_command, with use_unsafe_shell=True, shlex_quote's each
      # element and joins them with spaces before the shell ever sees
      # the string. Live-verified: `shell: {argv: [echo, "hello
      # world"]}` -> stdout "hello world". (argv: isn't in shell's own
      # public docs even though it's functional there.) Element-wise
      # single-quoting here is shell-equivalent to shlex_quote and
      # never whitespace-splits an element - that's the whole point of
      # argv: over cmd:/free-form.
      argv_parts = argv.try { |raw| parse_argv_list(raw) }

      # Check creates parameter (idempotency). `path_or_glob_exists?`
      # (not the old `remote_file_exists?`, which - literal-only and
      # via a shell `test -f` for a remote connection - neither
      # understood a glob pattern nor matched real Ansible's own
      # `glob.glob(path)` check) - see that helper's own comment
      # (appsilon.mount_efs's `creates: ".../amazon-efs-utils*deb"`).
      # This plugin already runs ON the target (uploaded+executed
      # remotely, or run locally for a local connection) like every
      # other non-controller-only plugin, so a plain local Dir.glob
      # call here already checks the right (target) filesystem - no
      # separate remote branch needed. Message wording matches real
      # Ansible's own exactly (live-verified against ansible-core
      # 2.19.4), not just the functional result.
      # The skip result also carries the FULL command-module shape (rc: 0,
      # cmd, stdout_lines, empty stderr/stderr_lines, null start/end/delta)
      # - real 2.19.4 populates all of those keys on a creates:/removes:
      # skip (see command.cr's identical fix for the full breakdown). A
      # bare msg/stdout result made any `register:` + changed_when:
      # reading of `.rc` on the skip hard-fail where real Ansible
      # evaluates cleanly (konstruktoid.docker_rootless's warm run).
      # Read chdir here (pure parameter read, no side effect - the shell's
      # own `cd` still happens further down) so the creates:/removes:
      # checks below resolve a RELATIVE path against it, matching real
      # Ansible's command/shell action plugin. Same kyl191.openvpn-shaped
      # divergence as command.cr's copy of this fix - see that one.
      chdir = @params["chdir"]?

      if creates = @params["creates"]?
        if path_or_glob_exists?(resolve_against_chdir(creates, chdir))
          skipped_stdout = "skipped, since #{creates} exists"
          # Real ansible-core 2.19.11 words the check-mode variant of this
          # msg "Would not run command since ..." (the ordinary run says
          # "Did not run command since ..." - live-verified both).
          skip_msg = @check_mode ? "Would not run command since '#{creates}' exists" : "Did not run command since '#{creates}' exists"
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: skip_msg,
            cmd: cmd,
            rc: 0,
            stdout: skipped_stdout,
            stdout_lines: [skipped_stdout],
            stderr: "",
            stderr_lines: [] of String,
            start: nil,
            end: nil,
            delta: nil
          )
        end
      end

      # Check removes parameter (conditional execution) - same real-
      # Ansible message shape as creates: above, with the same full
      # command-module result keys (see the creates: branch).
      if removes = @params["removes"]?
        unless path_or_glob_exists?(resolve_against_chdir(removes, chdir))
          skipped_stdout = "skipped, since #{removes} does not exist"
          skip_msg = @check_mode ? "Would not run command since '#{removes}' does not exist" : "Did not run command since '#{removes}' does not exist"
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: skip_msg,
            cmd: cmd,
            rc: 0,
            stdout: skipped_stdout,
            stdout_lines: [skipped_stdout],
            stderr: "",
            stderr_lines: [] of String,
            start: nil,
            end: nil,
            delta: nil
          )
        end
      end

      # Shell commands don't support check mode (Ansible behavior). Real
      # Ansible's own command/shell action plugin still populates the
      # FULL normal result shape (cmd/rc/stdout/stdout_lines/stderr/
      # stderr_lines/start/end/delta, all empty/zero/null) rather than a
      # bare skip marker - `register:`-ing this and referencing e.g.
      # `{{ result.stdout }}` downstream (a real, common check-mode-
      # tolerant pattern) needs `stdout` to genuinely be `""`, not
      # missing entirely, or strict module-arg templating (see
      # VarSubstitutor::UndefinedVariableError) now correctly fails the
      # referencing task exactly like real Ansible would if the KEY were
      # actually missing - it just isn't, here. Verified live against
      # ansible-core 2.19.4's own `--check` output for this exact case.
      # The `skipping:` verdict only applies when NO creates:/removes:
      # gate is present - see command.cr's identical fix (live-verified
      # against 2.19.11) for the full gate-vs-skip breakdown.
      if @check_mode
        gated = @params.has_key?("creates") || @params.has_key?("removes")
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "Command would have run if not in check mode",
          skipped: !gated,
          cmd: cmd,
          rc: 0,
          stdout: "",
          stdout_lines: [] of String,
          stderr: "",
          stderr_lines: [] of String,
          start: nil,
          end: nil,
          delta: nil
        )
      end

      # Get optional parameters
      executable = @params["executable"]? || "/bin/sh"

      # Build full command. argv: form is quoted element-wise and joined
      # (see the comment above); cmd:/free-form is passed through verbatim
      # - the shell does the splitting. `command_string` (the pre-chdir
      # form) is what real Ansible's shell module reports as the result's
      # `cmd` key - the raw command string, not the argv list command uses
      # and not the `cd X && ...` prefixed form the shell actually runs.
      command_string = argv_parts ? argv_parts.map { |arg| shell_single_quote(arg) }.join(" ") : cmd.to_s

      full_cmd = command_string

      # Add chdir if specified
      if chdir
        full_cmd = "cd #{chdir} && #{full_cmd}"
      end

      # Real Ansible's run_command tries os.chdir(chdir) BEFORE spawning
      # anything, so a nonexistent/non-directory chdir fails the MODULE
      # (changed: false, rc: null, full command-module shape) instead of
      # surfacing as a shell exit code with changed: true - the `cd X
      # &&` prefix above would have run and failed inside the shell.
      # Same up-front check as command.cr's, with the rc:null shape
      # run_command actually produces (live-verified against 2.19.4;
      # found via the podman-diff command_edge_cases C9 harness case).
      if chdir && !File.directory?(expand_tilde(chdir))
        reason = File.exists?(expand_tilde(chdir)) ? "Not a directory" : "No such file or directory"
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to change directory to #{chdir}: #{reason}",
          cmd: command_string,
          rc: nil,
          stdout: "",
          stdout_lines: [] of String,
          stderr: "",
          stderr_lines: [] of String,
          start: nil,
          end: nil,
          delta: nil
        )
      end

      # Real Ansible hands `executable:` to run_command as the SHELL
      # BINARY itself (subprocess executable=), so a nonexistent one
      # raises OSError before any process starts: fail_json(rc=e.errno,
      # msg="[Errno 2] No such file or directory: b'...'") - changed
      # stays FALSE and rc is the raw errno (2 for ENOENT, 13 for
      # EACCES), not a shell "command not found" exit code with changed:
      # true. This engine's remote_exec would have reported exactly
      # that (changed=true, rc=1) - live-verified divergence via the
      # podman-diff command_edge_cases C5 harness case.
      if executable != "/bin/sh"
        unless File.file?(executable)
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "No such file or directory: '#{executable}'",
            cmd: command_string,
            rc: 2,
            exit_code: 2,
            stdout: "",
            stdout_lines: [] of String,
            stderr: "",
            stderr_lines: [] of String,
            start: nil,
            end: nil,
            delta: nil
          )
        end
        unless File.executable?(executable)
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Permission denied: '#{executable}'",
            cmd: command_string,
            rc: 13,
            exit_code: 13,
            stdout: "",
            stdout_lines: [] of String,
            stderr: "",
            stderr_lines: [] of String,
            start: nil,
            end: nil,
            delta: nil
          )
        end
      end

      # Give this process (and therefore the shell it is about to
      # spawn, and everything under it) a controlling terminal, the way
      # real ansible-core's `ssh -tt` does for the whole remote process
      # tree - see ControllingTty's own comment for why the tty is
      # manufactured here rather than requested from ssh. No-op when one
      # already exists (local connection from a real terminal), and a
      # no-op fallback to today's behavior if it cannot be arranged.
      ControllingTty.ensure

      # Execute command
      # Note: the command is ALWAYS handed to the module's `executable:`
      # shell (default /bin/sh) via `<executable> -c <string>` - real
      # Ansible's shell module (command.py with _uses_shell) runs
      # run_command with the argspec's executable as the shell BINARY,
      # so the default is /bin/sh (dash on Debian), NOT bash. This
      # engine's remote_exec/LocalExecutor wraps shell-forced strings in
      # `bash -c` for its own env-prefix/glob needs, which silently gave
      # the default-shell case bash semantics: `shell: 'if [[ -n
      # "$BASH_VERSION" ]]...'` succeeded as "bash-here" where real
      # /bin/sh correctly printed "not-bash" (found via the podman-diff
      # shell_edge_cases SH4b case). Explicitly invoking the same
      # `<executable> -c <quoted string>` form for the default as for a
      # custom executable makes the outer wrapper irrelevant - the
      # module's own shell does the interpreting, exactly like real.
      remote_command = "#{executable} -c #{shell_single_quote(full_cmd)}"

      # stdin: (+ stdin_add_newline:) - real Ansible hands `data` directly
      # to the spawned command's stdin, appending a newline unless
      # stdin_add_newline is explicitly false (basic.py run_command:
      # `if not binary_data: data += '\n'`, with binary_data wired to
      # `not stdin_add_newline`) - live-verified against 2.19.4 on shell:
      # `wc -l` fed "line1\nline2" counts 2 lines by default, 1 with
      # stdin_add_newline: false. This plugin executes through
      # remote_exec (a shell string over SSH/local), so the same bytes
      # reach the command's stdin by piping a printf; the observable
      # behavior is identical. The `{ ...; }` group keeps operators
      # inside full_cmd (its own pipes, the `cd X && ...` prefix) on the
      # RIGHT side of the pipe, and propagates the command's own exit
      # code unchanged. single-quoted printf data is literal to the
      # shell (newlines, quotes and all) via #shell_single_quote.
      if stdin_data = @params["stdin"]?
        stdin_add_newline = true?(@params["stdin_add_newline"]?, default: true)
        stdin_payload = stdin_add_newline ? "#{stdin_data}\n" : stdin_data
        remote_command = "printf %s #{shell_single_quote(stdin_payload)} | { #{remote_command}; }"
      end

      # force_shell: the shell module's string is ALWAYS interpreted by
      # the shell on the target, even when it has no metacharacters -
      # without this, a builtin-only command like `command -v foo`
      # would be argv-split and direct-exec'd (and fail: there is no
      # `command` binary), where real Ansible's shell module always
      # runs it through /bin/sh.
      result = remote_exec(remote_command, force_shell: true)

      # Build diff data if diff mode enabled
      diff_data = nil
      if @diff_mode
        diff_hash = {
          "prepared" => "$ #{full_cmd}\n#{result[:stdout]}",
        }
        diff_data = JSON.parse(diff_hash.to_json)
      end

      # Shell commands always report changed (Ansible behavior)
      # unless they were skipped by creates/removes
      #
      # strip_empty_ends (bool, default true): when true, real Ansible
      # rstrips ALL trailing \r/\n characters from stdout/stderr (its
      # command.py: `if strip: r['stdout'] = to_text(r['stdout'])
      # .rstrip("\r\n")`); when false, the raw bytes are returned
      # untouched (live-verified: printf 'out\n\n\n' keeps all 6 bytes
      # with strip_empty_ends: false, collapses to "out" with the
      # default). The result carries the FULL real shell-module shape:
      # cmd is the raw command string, stdout_lines/stderr_lines are
      # derived here (module-side, where real Ansible's command.py sets
      # them) from the same splitlines() semantics the executor used to
      # derive them centrally from (Python's str.splitlines()), and msg
      # is left empty on success - real Ansible's shell module NEVER sets
      # msg on success (PluginResult omits an empty msg from the wire
      # JSON), and the previous "Command executed successfully" text
      # showed up as a nonstandard key in ad-hoc (`ansible -m shell`)
      # result output. Crystal's String#rstrip(set) strips trailing
      # chars from the set, exactly like Python's str.rstrip("\r\n").
      strip_empty_ends = true?(@params["strip_empty_ends"]?, default: true)
      final_stdout = strip_empty_ends ? result[:stdout].rstrip("\r\n") : result[:stdout]
      final_stderr = strip_empty_ends ? result[:stderr].rstrip("\r\n") : result[:stderr]

      PluginResult.new(
        changed: true,
        failed: result[:exit_code] != 0,
        msg: result[:exit_code] == 0 ? "" : "Command failed",
        include_empty_msg: true,
        cmd: command_string,
        stdout: final_stdout,
        stdout_lines: PluginHelpers::AnsibleSplitlines.split(final_stdout),
        stderr: final_stderr,
        stderr_lines: PluginHelpers::AnsibleSplitlines.split(final_stderr),
        exit_code: result[:exit_code],
        rc: result[:exit_code], # Add rc as alias for Ansible compatibility
        diff: diff_data
      )
    end

    # Parses `argv:`'s JSON-array text into its literal argument list -
    # command.cr's own copy, shared rationale: no shell splitting/quoting
    # at all at parse time (the elements are only shell-quoted when the
    # full command string is assembled, mirroring real Ansible's
    # shlex_quote + " ".join). A whole-value `{{ list_var }}` container
    # arg arrives as the double-quoted JSON the wire serialized it to
    # (see substitute_task_params's whole-single-span comment); ONLY that
    # valid JSON is parsed - never a Python-repr repair pass, since a
    # value that merely LOOKS like a container is a plain STRING in real
    # ansible-core (live-verified vs ansible-playbook 2.19.11, see
    # apt.cr's parse_package_names).
    private def parse_argv_list(raw : String) : Array(String)
      Array(String).from_json(raw.strip)
    end

    # Helper to convert string/bool to boolean
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ShellPlugin.new(config)
plugin.run
