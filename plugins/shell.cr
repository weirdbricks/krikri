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

      # Get command (supports both direct string and 'cmd' parameter)
      cmd = @params["_raw_params"]? || @params["cmd"]?
      unless cmd
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: cmd"
        )
      end

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
      if creates = @params["creates"]?
        if path_or_glob_exists?(expand_tilde(creates))
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Did not run command since '#{creates}' exists",
            stdout: "skipped, since #{creates} exists"
          )
        end
      end

      # Check removes parameter (conditional execution) - same real-
      # Ansible message shape as creates: above.
      if removes = @params["removes"]?
        unless path_or_glob_exists?(expand_tilde(removes))
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Did not run command since '#{removes}' does not exist",
            stdout: "skipped, since #{removes} does not exist"
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
      chdir = @params["chdir"]?
      executable = @params["executable"]? || "/bin/sh"

      # Build full command
      full_cmd = cmd.to_s

      # Add chdir if specified
      if chdir
        full_cmd = "cd #{chdir} && #{full_cmd}"
      end

      # Execute command
      # Note: remote_exec() already executes through a shell, so we don't need to
      # wrap the command in another shell invocation. This allows shell operators
      # like ||, &&, |, >, etc. to work properly.
      #
      # If a custom executable is specified (not /bin/sh), we need to explicitly
      # invoke it since remote_exec uses /bin/sh by default
      result = if executable == "/bin/sh"
                 # Default shell - just pass the command directly
                 remote_exec(full_cmd)
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
                 remote_exec("#{executable} -c #{shell_single_quote(full_cmd)}")
               end

      # Build diff data if diff mode enabled
      diff_data = nil
      if @diff_mode
        diff_hash = {
          "prepared" => "$ #{cmd}\n#{result[:stdout]}",
        }
        diff_data = JSON.parse(diff_hash.to_json)
      end

      # Shell commands always report changed (Ansible behavior)
      # unless they were skipped by creates/removes
      PluginResult.new(
        changed: true,
        failed: result[:exit_code] != 0,
        msg: result[:exit_code] == 0 ? "Command executed successfully" : "Command failed",
        stdout: result[:stdout].rstrip("\r\n"),
        stderr: result[:stderr].rstrip("\r\n"),
        exit_code: result[:exit_code],
        rc: result[:exit_code], # Add rc as alias for Ansible compatibility
        diff: diff_data
      )
    end

    # Helper to convert string/bool to boolean
    private def true?(value) : Bool
      return false if value.nil?
      value_str = value.to_s.downcase
      value_str == "true" || value_str == "yes" || value_str == "1"
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ShellPlugin.new(config)
plugin.run
