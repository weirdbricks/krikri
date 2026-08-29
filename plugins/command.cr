#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Command plugin - executes commands
  # Compatible with Ansible's ansible.builtin.command module
  #
  # Parameters:
  #   cmd: Command to execute (or use _raw_params for free-form)
  #   chdir: Change directory before executing
  #   creates: Skip if this file exists (idempotency)
  #   removes: Skip if this file doesn't exist (idempotency)
  #   stdin: Data to send to stdin
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
      @check_mode = is_true?(@params["check_mode"]?)
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

      # Get command (supports both 'cmd' and free-form)
      cmd = @params["cmd"]? || @params["_raw_params"]?

      unless cmd
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: cmd"
        )
      end

      # Check creates parameter (idempotency)
      if creates = @params["creates"]?
        if File.exists?(expand_tilde(creates))
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Skipped: #{creates} already exists",
            skipped: true
          )
        end
      end

      # Check removes parameter (conditional execution)
      if removes = @params["removes"]?
        unless File.exists?(expand_tilde(removes))
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Skipped: #{removes} does not exist",
            skipped: true
          )
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
      chdir = @params["chdir"]?.try { |c| expand_tilde(c) }
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
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to change directory to #{chdir}: #{ex.message}"
          )
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
        cmd_parts = parse_command(cmd)
        command_name = cmd_parts.first
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

        process = Process.new(
          command_name,
          args,
          env: task_environment,
          output: stdout,
          error: stderr,
          input: stdin_data ? Process::Redirect::Pipe : Process::Redirect::Close
        )

        # Send stdin if provided
        if stdin_data && process.input
          process.input.print(stdin_data)
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
        return PluginResult.new(
          changed: true,
          failed: true,
          msg: "Failed to execute command: #{ex.message}",
          stdout: "",
          stderr: ex.message || "",
          exit_code: 2,
          rc: 2
        )
      end

      # Command module always reports changed (unless skipped)
      # This matches Ansible behavior
      PluginResult.new(
        changed: true,
        failed: exit_code != 0,
        msg: exit_code == 0 ? "Command executed successfully" : "Command failed with exit code #{exit_code}",
        stdout: stdout.to_s.rstrip("\r\n"),
        stderr: stderr.to_s.rstrip("\r\n"),
        exit_code: exit_code,
        rc: exit_code # Add rc as alias for Ansible compatibility
      )
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
    private def task_environment : Process::Env
      env_json = @params["_environment"]?
      return nil unless env_json

      env = Hash(String, String).from_json(env_json)
      env.empty? ? nil : env.transform_values { |v| v.as(String?) }
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

    # Helper: Check if parameter is truthy
    private def is_true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::CommandPlugin.new(config)
plugin.run
