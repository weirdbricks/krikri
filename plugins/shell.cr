#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

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
    property? check_mode : Bool
    property? diff_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
      @diff_mode = true?(@params["diff_mode"]?)
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
      # Same `warn:` rejection as command.cr - real ansible-core 2.19
      # rejects the removed param identically (message adjusted for the
      # shell module's own supported-parameter list; the tail after
      # "warn." matches ansible-core 2.19's shell argspec).
      if @params.has_key?("warn")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (ansible.legacy.shell) module: warn. Supported parameters include: _raw_params, _uses_shell, argv, chdir, cmd, creates, executable, expand_argument_vars, removes, stdin, stdin_add_newline, strip_empty_ends."
        )
      end

      # Real Ansible 2.19.4 REJECTS `expand_argument_vars:` on shell
      # outright - live-verified: the shell module's own argspec doesn't
      # include it (only command's does), so the task fails before the
      # command ever runs with exactly:
      #   {"changed": false, "msg": "Unsupported parameters for (shell)
      #   module: expand_argument_vars"}
      # (note: no "Supported parameters include" tail, unlike the warn:
      # rejection above). There is therefore NO shell-side
      # expand_argument_vars behavior to implement - rejecting it, with
      # this exact message, IS the real-Ansible behavior. ($VAR expansion
      # on shell's cmd:/free-form happens in the shell interpreter
      # itself, and argv: elements are shlex_quote'd by real Ansible
      # before the shell sees them, so nothing here is left unexpanded.)
      if @params.has_key?("expand_argument_vars")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (shell) module: expand_argument_vars"
        )
      end

      # Get command (supports direct string, 'cmd' parameter, or 'argv')
      cmd = @params["_raw_params"]? || @params["cmd"]?
      argv = @params["argv"]?
      unless cmd || argv
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: cmd"
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
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Did not run command since '#{creates}' exists",
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
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Did not run command since '#{removes}' does not exist",
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
      if @check_mode
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "Command would have run if not in check mode",
          skipped: true,
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
      # - the shell does the splitting.
      full_cmd = argv_parts ? argv_parts.map { |arg| shell_single_quote(arg) }.join(" ") : cmd.to_s

      # Add chdir if specified
      if chdir
        full_cmd = "cd #{chdir} && #{full_cmd}"
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
      # Note: remote_exec() already executes through a shell, so we don't need to
      # wrap the command in another shell invocation. This allows shell operators
      # like ||, &&, |, >, etc. to work properly.
      #
      # If a custom executable is specified (not /bin/sh), we need to explicitly
      # invoke it since remote_exec uses /bin/sh by default
      remote_command = if executable == "/bin/sh"
                 # Default shell - just pass the command directly
                 full_cmd
               else
                 # Custom shell - invoke it explicitly. full_cmd routinely
                 # contains its own single quotes (`cut -d' ' -f2`, `tr -d
                 # 'v'` - ansible-community.ansible-vault's own "Get
                 # installed Vault version" task uses both) - naively
                 # wrapping it in another bare `'...'` pair let those
                 # embedded quotes prematurely close the outer quoting,
                 # corrupting the command bash actually saw. Real bug
                 # found benchmarking that role: "cut: option requires an
                 # argument -- 'd'" with the rest of the pipeline showing
                 # up as unquoted trailing shell text.
                 "#{executable} -c #{shell_single_quote(full_cmd)}"
               end

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

      result = remote_exec(remote_command)

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
      # default). The executor derives stdout_lines/stderr_lines
      # centrally from whatever lands here, so the *_lines keys follow
      # automatically. Crystal's String#rstrip(set) strips trailing
      # chars from the set, exactly like Python's str.rstrip("\r\n").
      strip_empty_ends = true?(@params["strip_empty_ends"]?, default: true)

      PluginResult.new(
        changed: true,
        failed: result[:exit_code] != 0,
        msg: result[:exit_code] == 0 ? "Command executed successfully" : "Command failed",
        stdout: strip_empty_ends ? result[:stdout].rstrip("\r\n") : result[:stdout],
        stderr: strip_empty_ends ? result[:stderr].rstrip("\r\n") : result[:stderr],
        exit_code: result[:exit_code],
        rc: result[:exit_code], # Add rc as alias for Ansible compatibility
        diff: diff_data
      )
    end

    # Parses `argv:`'s JSON-array text into its literal argument list -
    # command.cr's own copy, shared rationale: no shell splitting/quoting
    # at all at parse time (the elements are only shell-quoted when the
    # full command string is assembled, mirroring real Ansible's
    # shlex_quote + " ".join). A templated Jinja list var renders as
    # Python's repr (single-quoted strings) rather than JSON when it
    # comes through a `{% if %}...{{ [list] }}...{% endif %}` idiom -
    # same fallback as rpm_package.cr's/apt.cr's own copies of this
    # pattern.
    private def parse_argv_list(raw : String) : Array(String)
      trimmed = raw.strip
      begin
        Array(String).from_json(trimmed)
      rescue
        Array(String).from_json(trimmed.gsub('\'', '"'))
      end
    end

    # Helper to convert string/bool to boolean
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ShellPlugin.new(config)
plugin.run
