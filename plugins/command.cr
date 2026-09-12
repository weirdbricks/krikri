#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Command plugin - executes commands
  # Compatible with Ansible's ansible.builtin.command module
  #
  # Parameters:
  #   cmd: Command to execute (or use _raw_params for free-form)
  #   chdir: Change directory before executing
  #   creates: Skip if this file exists (idempotency)
  #   removes: Skip if this file doesn't exist (idempotency)
  #   stdin: Data to send to stdin
  #   stdin_add_newline: Append a newline to stdin: (default true)
  #   strip_empty_ends: Rstrip trailing newlines from stdout:/stderr:
  #     (default true)
  #   executable: Accepted but IGNORED with a warning (real Ansible 2.4+
  #     behavior - see #executable_warning below)
  #   check_mode: Dry-run mode (command plugin always skips in check mode)
  #
  # Examples:
  #   command: echo "Hello World"
  #
  #   command: /usr/bin/make
  #   args:
  #     chdir: /opt/myapp
  #     creates: /opt/myapp/built.flag
  #
  # stdout:/stderr: are rstripped of a trailing \r\n before being returned
  # (matching real Ansible's own AnsibleModule.run_command(), which does
  # the same) - found the hard way, not assumed: a real playbook
  # comparing `result.stdout == "someuser"` after `command: whoami`
  # failed here despite the values looking identical when printed,
  # because the captured stdout still had its trailing newline; real
  # ansible-playbook strips it, so real playbooks are routinely written
  # assuming stdout has no trailing newline.
  class CommandPlugin < BasePlugin
    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
    end

    # Resolves a creates:/removes: path for the existence check above:
    # a RELATIVE path is joined onto chdir: (real Ansible's own
    # behavior), an already-absolute path is used as-is (chdir: never
    # changes an absolute path's meaning), and a leading ~ was already
    # expanded by #expand_tilde to an absolute home path. No Dir.cd
    # here and no cwd side effects - when the file exists the task
    # skips cleanly without ever needing to change directory at all.
    private def resolve_against_chdir(path : String, chdir : String?) : String
      expanded = expand_tilde(path)
      return expanded if chdir.nil? || expanded.starts_with?('/')
      File.join(chdir, expanded)
    end

    # Real Ansible 2.19.4's command module still ACCEPTS `executable:` but
    # ignores it entirely - main() drops it with `module.warn(...)` when
    # _uses_shell is false, and the task succeeds normally. Live-verified:
    # `command: {cmd: "echo hi", executable: /bin/bash}` runs `echo` via
    # execvp (no shell) and the result carries:
    #   "warnings": ["As of Ansible 2.4, the parameter 'executable' is no
    #   longer supported with the 'command' module. Not using '/bin/bash'."]
    # This engine previously never read the param at all (silent tolerance,
    # no warning). module.warn accumulates into whatever exit_json/fail_json
    # comes next, so the warning is attached to EVERY result after arg
    # validation - skip (creates:/removes:), check mode, chdir failure,
    # spawn failure, and normal execution alike.
    private def executable_warning : Array(String)?
      exe = @params["executable"]?
      return nil unless exe
      ["As of Ansible 2.4, the parameter 'executable' is no longer supported with the 'command' module. Not using '#{exe}'."]
    end

    # Attaches #executable_warning to a result using the same
    # extra["warnings"] convention apache2_module.cr already uses
    # (matches real Ansible's top-level result["warnings"] list).
    private def with_executable_warning(result : PluginResult) : PluginResult
      if warnings = executable_warning
        result.extra["warnings"] = JSON.parse(warnings.to_json)
      end
      result
    end

    def execute : PluginResult
      # Real ansible-core 2.19 removed the long-deprecated `warn:` param
      # from command/shell and now rejects it at module-arg validation
      # with exactly this message. Found live-benchmarking
      # cloudalchemy.node_exporter / cloudalchemy.bind_exporter (round
      # 195 re-runs): both roles' "Gather currently installed version"
      # command tasks carry `warn:`, which only runs on the WARM pass
      # (the version probe is skipped cold because the binary doesn't
      # exist yet), so cold ran clean on both engines and warm diverged -
      # real ansible rc=2 "Unsupported parameters ... warn", crystal
      # tolerated it and rc=0'd. This engine now rejects it the same way
      # (same message, shell.cr shares this via its own copy below).
      if @params.has_key?("warn")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (ansible.legacy.command) module: warn. Supported parameters include: _raw_params, _uses_shell, argv, chdir, cmd, creates, executable, expand_argument_vars, removes, stdin, stdin_add_newline, strip_empty_ends."
        )
      end

      # Get command (supports 'cmd', free-form, or 'argv')
      cmd = @params["cmd"]? || @params["_raw_params"]?
      argv = @params["argv"]?

      unless cmd || argv
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: cmd"
        )
      end

      # `argv:` gives the exact argument list literally - no shell
      # quoting/splitting at all, real ansible-core's own command.py runs
      # it via `run_command(argv, ...)` (a list) rather than shlex-
      # splitting a string. Kept as its own cmd_parts source rather than
      # joining into a `cmd` string and reusing #parse_command below,
      # which would re-introduce exactly the quoting argv exists to
      # avoid (kyl191.openvpn's own `-subj /CN={{ openvpn_ca_cn[:64]
      # }}/` argv element, containing spaces from a CN value, must reach
      # openssl as ONE argument). `cmd` is left nil (not the joined
      # argv) for `changed_when:`/display purposes - real Ansible's own
      # `result['cmd']` is the argv LIST itself in this shape, but this
      # plugin's PluginResult#cmd is typed String; the argv path skips
      # the `unless cmd` check above via the OR, so this is unreachable
      # with cmd nil only via that path.
      argv_parts = argv.try { |raw| parse_argv_list(raw) }

      # Check creates parameter (idempotency). Real Ansible reports this
      # as an ORDINARY "ok" result (changed: false), never a task-level
      # "skipping:" - `skipped:` here used to be a genuine divergence in
      # its own right (this codebase's recap counted it under
      # `skipped=`, real Ansible's own recap counts it under `ok=`),
      # confirmed live against ansible-core 2.19.4: `ok: [localhost] =>
      # {"changed": false, ..., "msg": "Did not run command since '...'
      # exists"}`, recap `ok=1 skipped=0`.
      # The result also carries the FULL command-module shape (rc: 0, cmd,
      # stdout_lines, empty stderr/stderr_lines, null start/end/delta) -
      # verified live against 2.19.4 (`{"changed": false, "rc": 0, ...
      # "stdout": "skipped, since ... exists", "stdout_lines": [...]}`).
      # konstruktoid.docker_rootless's own "Enable lingering for the Docker
      # user" task registers this very skip and reads `user_linger.rc` in
      # its changed_when: (rc==0 AND stdout not containing 'skipped' ->
      # changed: false) - with `rc` missing the attribute access hard-
      # failed the warm run ("object of type 'dict' has no attribute
      # 'rc'") where real Ansible evaluates cleanly.
      # Read chdir here (a pure parameter read, no side effect - the
      # actual Dir.cd still only happens further down, right before
      # executing the command) so the creates:/removes: checks below can
      # resolve a RELATIVE path against it. Real Ansible's own
      # command/shell action plugin resolves a relative creates:/removes:
      # against chdir: when both are given (chdir changes what
      # "relative" means for the whole task, not just the command's own
      # execution). Found via kyl191.openvpn's warm run: its "Generate CA
      # key" task (argv: openssl req ..., chdir: "{{ openvpn_key_dir }}",
      # creates: ca-key.pem) re-ran on every single warm pass because
      # the check below tested "ca-key.pem" against the plugin process's
      # own inherited cwd (the SSH session's home) instead of
      # openvpn_key_dir, never finding the file and always concluding
      # "must run" - where real ansible-playbook reported changed=0.
      chdir = @params["chdir"]?.try { |itm| expand_tilde(itm) }

      if creates = @params["creates"]?
        if path_or_glob_exists?(resolve_against_chdir(creates, chdir))
          skipped_stdout = "skipped, since #{creates} exists"
          return with_executable_warning(PluginResult.new(
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
          ))
        end
      end

      # Check removes parameter (conditional execution) - same real-
      # Ansible "ok", not "skipping:", shape as creates: above, with the
      # same full command-module result keys (see the creates: branch).
      if removes = @params["removes"]?
        unless path_or_glob_exists?(resolve_against_chdir(removes, chdir))
          skipped_stdout = "skipped, since #{removes} does not exist"
          return with_executable_warning(PluginResult.new(
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
          ))
        end
      end

      # Command module doesn't support check mode (Ansible behavior). Real
      # Ansible's own command/shell action plugin still populates the FULL
      # normal result shape (cmd/rc/stdout/stdout_lines/stderr/
      # stderr_lines/start/end/delta, all empty/zero/null) rather than a
      # bare skip marker - see shell.cr's identical fix for why this
      # matters now that module-arg templating is strict (verified live
      # against ansible-core 2.19.4's own `--check` output).
      if @check_mode
        return with_executable_warning(PluginResult.new(
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
        ))
      end

      # Get optional parameters
      stdin_data = @params["stdin"]?

      # Change directory if requested. No need to track/restore the
      # original directory afterwards - this plugin process runs once
      # and exits, it never returns to running further code in the
      # process's own original cwd. A prior version DID try to restore
      # it (`Dir.cd(original_dir)` in both the exec-failure rescue and
      # after a successful run below), which was worse than a no-op: on
      # a remote SSH+`become_user:` invocation, the process starts with
      # cwd inherited from the SSH login user's home (root's, `/root`,
      # mode 700) - restoring to that path as an unprivileged
      # become_user with no permission on `/root` at all raised an
      # uncaught `Dir.cd` exception AFTER the real command had already
      # run successfully, crashing an otherwise-successful task.
      # ssh_hardening/nextcloud-shaped `command: ... chdir: X become_user:
      # www-data` tasks hit this every time. Found via
      # robertdebock.nextcloud's own `Configure nextcloud` task
      # (`chdir: /var/www/html/nextcloud`, `become_user: www-data`).
      if chdir
        begin
          Dir.cd(chdir)
        rescue ex
          return with_executable_warning(PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to change directory to #{chdir}: #{ex.message}"
          ))
        end
      end

      # Execute command using Crystal's Process
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      exit_code = 0

      begin
        # Parse command into array (simple split on spaces)
        # Note: This doesn't handle quoted arguments perfectly
        # but works for most cases
        cmd_parts = argv_parts || (cmd ? parse_command(cmd) : [] of String)
        # Real Ansible's AnsibleModule.run_command (expand_user_and_vars,
        # driven by the command module's expand_argument_vars, default true)
        # expands BOTH `~` (including the `~user` form, via the passwd
        # database - not a shell, so this happens even though command: runs
        # nothing through one) and `$VAR`/`${VAR}` on EVERY argv token, not
        # just the executable. `command: tar -xzf /tmp/x.tar.gz -C ~root/bin
        # starship` (viasite-ansible.zsh's "Extract starship to ~root/bin"
        # task, round 200970) left `~root/bin` literal as tar's -C argument
        # and failed with "tar: ~root/bin: Cannot open" where real Ansible
        # ran it at /root/bin. Order matches Python's own
        # os.path.expanduser(os.path.expandvars(x)): variables first, then
        # tilde, so `~$USER` resolves.
        if true?(@params["expand_argument_vars"]?, default: true)
          cmd_parts = cmd_parts.map { |part| expand_user_and_vars(part) }
        end
        command_name = cmd_parts.first
        # Real Ansible's AnsibleModule.run_command (expand_user=True, the
        # default) os.path.expanduser's the executable, so
        # `command: '~/.rvm/bin/rvm autolibs 4'` runs the binary at the
        # invoking user's home (rvm.ruby's own "Configure rvm" task:
        # `command: '{{ rvm1_rvm }} autolibs ...'` with
        # `rvm1_rvm: ~/.rvm/bin/rvm` - real Ansible changed, this engine
        # failed with "Error executing process: '~/.rvm/bin/rvm': No such
        # file or directory"). expand_tilde is the same HOME-first
        # expansion Python's own expanduser does.
        command_name = expand_tilde(command_name)
        args = cmd_parts[1..]

        # Process.new's `env:` sets the CHILD's environment, but the
        # executable lookup itself (execvp) searches the PARENT's PATH -
        # so `environment: PATH: <venv>/bin` + `command: ara-manage`
        # failed with "No such file or directory" even though the binary
        # exists in the overridden PATH (real Ansible runs commands via
        # /bin/sh -c with the env exported FIRST, so its lookup uses the
        # new PATH - buluma.ara_api's migration task, round 190).
        # Resolve the executable against the task's own PATH override
        # before spawning; fall back to the bare name (parent PATH
        # lookup, unchanged behavior without an override).
        if (task_env = task_environment) && (override_path = task_env["PATH"]?)
          resolved = resolve_in_path(command_name, override_path)
          command_name = resolved if resolved
        end

        # Give this process (and therefore the command spawned below,
        # and everything under it) a controlling terminal, the way real
        # ansible-core's `ssh -tt` does for the whole remote process
        # tree - see ControllingTty's own comment for why the tty is
        # manufactured here rather than requested from ssh. stdin/
        # stdout/stderr of the spawned command are untouched by this:
        # the tty is reachable only by explicitly opening /dev/tty, so
        # stdout and stderr stay the separate pipes they already were
        # (real Ansible's own module keeps them separate too - only its
        # ssh-level channel is merged by -tt).
        ControllingTty.ensure

        process = Process.new(
          command_name,
          args,
          env: task_environment,
          output: stdout,
          error: stderr,
          input: stdin_data ? Process::Redirect::Pipe : Process::Redirect::Close
        )

        # Send stdin if provided. Real Ansible appends a newline to the
        # data unless stdin_add_newline is explicitly false (its
        # run_command: `if not binary_data: data += '\n'`, with
        # binary_data wired to `not stdin_add_newline`) - live-verified
        # against 2.19.4: `wc -l` fed "line1\nline2" counts 2 lines by
        # default, 1 with stdin_add_newline: false.
        if stdin_data && process.input
          stdin_add_newline = true?(@params["stdin_add_newline"]?, default: true)
          process.input.print(stdin_add_newline ? "#{stdin_data}\n" : stdin_data)
          process.input.close
        end

        status = process.wait
        exit_code = status.exit_code
      rescue ex
        # Real Ansible's command module never gets here at all - Python's
        # `subprocess`/`AnsibleModule.run_command` catches ENOENT (a
        # nonexistent executable) itself and returns a normal (rc, stdout,
        # stderr) result (rc=2, empty stdout, an error message in stderr)
        # rather than raising, so a `register:`'d result always has
        # `.rc`/`.stdout`/`.stderr` populated even when the command fails
        # to spawn at all. This early return had none of those fields -
        # only `stderr` - so `failed_when: false` (the idiomatic "probe an
        # optional binary, don't fail the task" idiom) correctly kept the
        # TASK from failing, but a later `.stdout`/`.rc` reference on the
        # same registered variable was genuinely undefined instead of the
        # empty string/rc=2 real Ansible would have given it. Found via
        # konstruktoid.docker_rootless's own `command: .../docker version`
        # (`failed_when: false`, `register: rootless_docker_version`) on
        # a host where that binary doesn't exist yet - a LATER task's
        # `when: docker_release not in rootless_docker_version.stdout`
        # hard-failed with "'rootless_docker_version.stdout' is undefined"
        # where real Ansible just evaluates `not in ''`.
        return with_executable_warning(PluginResult.new(
          changed: true,
          failed: true,
          msg: "Failed to execute command: #{ex.message}",
          stdout: "",
          stderr: ex.message || "",
          exit_code: 2,
          rc: 2
        ))
      end

      # strip_empty_ends (bool, default true): when true, real Ansible
      # rstrips ALL trailing \r/\n characters from stdout/stderr
      # (`to_text(r['stdout']).rstrip("\r\n")` in its command.py, applied
      # only `if strip`); when false, the raw bytes are returned untouched
      # (live-verified: printf 'out\n\n\n' keeps all 6 bytes with
      # strip_empty_ends: false, collapses to "out" with the default).
      # The executor derives stdout_lines/stderr_lines centrally from
      # whatever lands here, so the *_lines keys follow automatically.
      # Crystal's String#rstrip(set) strips trailing chars from the set,
      # exactly like Python's str.rstrip("\r\n").
      strip_empty_ends = true?(@params["strip_empty_ends"]?, default: true)

      # Command module always reports changed (unless skipped)
      # This matches Ansible behavior
      with_executable_warning(PluginResult.new(
        changed: true,
        failed: exit_code != 0,
        msg: exit_code == 0 ? "Command executed successfully" : "Command failed with exit code #{exit_code}",
        stdout: strip_empty_ends ? stdout.to_s.rstrip("\r\n") : stdout.to_s,
        stderr: strip_empty_ends ? stderr.to_s.rstrip("\r\n") : stderr.to_s,
        exit_code: exit_code,
        rc: exit_code # Add rc as alias for Ansible compatibility
      ))
    end

    # Parse command string into command and arguments, honoring quoted
    # arguments. A naive space-split mangles a quoted arg like
    # `awk -F: '{print $1}' /etc/passwd` (used by dev-sec os_hardening)
    # into three broken pieces - awk then gets `'{print` as its program and
    # fails. Real Ansible's command module delivers the quoted text as one
    # argv element, so a quoted argument here is kept whole and the quotes
    # (single or double) stripped, matching how Process.new would have
    # received it under a shell-less invocation.
    # `environment:` (real Ansible's per-task env-var keyword), forwarded
    # here as a JSON blob under the `_environment` param key by
    # TaskExecutor#build_plugin_config (already {{ }}-substituted). Unlike
    # every other plugin, command.cr execs `command_name`/`args` directly
    # via Process.new rather than through a shell - BasePlugin#remote_exec's
    # `export K=V; ...` shell-prefix trick (which every *other* plugin's
    # shelled-out commands go through automatically) has nothing to attach
    # to here, so this reads the same `_environment` param directly and
    # passes it through Process.new's own `env:` instead.
    # Per-token expansion mirroring real Ansible's
    # `os.path.expanduser(os.path.expandvars(x))` (basic.py run_command):
    # variables first, then tilde.
    private def expand_user_and_vars(token : String) : String
      expand_tilde(expand_vars(token))
    end

    # os.path.expandvars semantics: `$VAR` and `${VAR}` are replaced from
    # the environment; an unset variable is left in place verbatim (never
    # an error). Lookup uses the task's own `environment:` override (via
    # the `_environment` param, same source Process.new gets) first so a
    # `environment: PATH: ...`-style variable expands to the task's value,
    # falling back to this process's inherited environment.
    private def expand_vars(s : String) : String
      task_env = task_environment
      String.build do |out_io|
        cursor = 0
        s.scan(/\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/) do |mat|
          out_io << s[cursor...mat.begin(0)]
          name = mat[1]? || mat[2]?
          next unless name
          out_io << (task_env.try(&.[]?(name)) || ENV[name]? || mat[0])
          cursor = mat.end(0)
        end
        out_io << s[cursor..]
      end
    end

    private def task_environment : Process::Env
      env_json = @params["_environment"]?
      return nil unless env_json

      env = Hash(String, String).from_json(env_json)
      env.empty? ? nil : env.transform_values { |v| v.as(String?) }
    end

    # Parses `argv:`'s JSON-array text into its literal argument list - no
    # shell splitting/quoting at all (that's the whole point of argv: over
    # cmd:/free-form). A templated Jinja list var renders as Python's repr
    # (single-quoted strings) rather than JSON when it comes through a
    # `{% if %}...{{ [list] }}...{% endif %}` idiom - same fallback as
    # rpm_package.cr's/apt.cr's own copies of this pattern.
    private def parse_argv_list(raw : String) : Array(String)
      trimmed = raw.strip
      begin
        Array(String).from_json(trimmed)
      rescue
        Array(String).from_json(trimmed.gsub('\'', '"'))
      end
    end

    # First executable file named *name* under the colon-separated
    # *path_override* (the task's own environment: PATH), or nil when the
    # name already contains a path separator (absolute/relative - used
    # verbatim, parent-process semantics) or nothing matches.
    private def resolve_in_path(name : String, path_override : String?) : String?
      return nil if name.includes?('/')
      path_override.try &.split(':').each do |dir|
        next if dir.empty?
        candidate = File.join(dir, name)
        return candidate if File.executable?(candidate) && !File.directory?(candidate)
      end
      nil
    end

    private def parse_command(cmd : String) : Array(String)
      parts = [] of String
      current = String::Builder.new
      in_single = false
      in_double = false
      started = false

      chars = cmd.each_char.to_a
      i = 0
      while i < chars.size
        char = chars[i]
        if in_single
          if char == '\''
            in_single = false
            started = true
          else
            current << char
          end
        elsif in_double
          if char == '"'
            in_double = false
            started = true
          else
            current << char
          end
        else
          case char
          when '\''
            in_single = true
            started = true
          when '"'
            in_double = true
            started = true
          when '\\'
            next_is_space_or_end = i + 1 >= chars.size || {' ', '\t', '\n'}.includes?(chars[i + 1])
            if !started && next_is_space_or_end
              # Real Ansible's task-arg parser (ansible.parsing.splitter.
              # split_args, run BEFORE Jinja templating on the whole `cmd:`/
              # `command:` string) treats a bare `\` - a whole token on its
              # own, delimited by whitespace or string boundaries on both
              # sides, exactly like split(' ')'s `token == '\\'` check -
              # as a line-continuation marker: dropped entirely, not an
              # escape of the following character. This is a documented,
              # intentional Ansible authoring convention for writing a
              # long `command:` as if it were multiple lines. Found
              # benchmarking buluma.influxdb2's own `influx ping \ --host
              # "{{ influxdb_host }}"` task: treating this `\ ` as "escape
              # this space into the current token" (the old, uniform
              # behavior below) produced a malformed `" --host"` argv
              # element (stray leading space) that real `influx`'s cobra-
              # based CLI parser rejects outright as an unknown
              # subcommand - while real ansible-playbook strips the lone
              # `\` and rejoins the remaining words with single spaces,
              # producing the well-formed `influx ping --host <url>` and
              # succeeding.
              i += 1 if i + 1 < chars.size
            elsif i + 1 < chars.size
              # Unquoted backslash-escape (shlex/POSIX shell semantics,
              # not just a literal character) - the char immediately
              # after is taken verbatim and the backslash itself dropped.
              # Real Ansible's command module parses `cmd:` the same way
              # (Python's shlex.split). Found via konstruktoid-hardening's
              # own `find ... -exec aa-enforce {} \;` - without this, the
              # final argv token was the two characters `\;` instead of
              # find's actual required terminator `;`, and find rejected
              # it outright ("missing argument to `-exec'"). This branch
              # only fires when the backslash is NOT a standalone token
              # (already part of a word, or followed by a non-whitespace
              # char) - see the line-continuation case above for the
              # whitespace-delimited case.
              current << chars[i + 1]
              i += 1
              started = true
            else
              current << char
              started = true
            end
          when ' ', '\t', '\n'
            if started
              parts << current.to_s
              current = String::Builder.new
              started = false
            end
          else
            current << char
            started = true
          end
        end
        i += 1
      end

      parts << current.to_s if started
      parts
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::CommandPlugin.new(config)
plugin.run
