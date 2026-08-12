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
    property check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
    end

    def execute : PluginResult
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

      # Command module doesn't support check mode (Ansible behavior)
      if @check_mode
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "Skipped: command module does not support check mode",
          skipped: true
        )
      end

      # Get optional parameters
      chdir = @params["chdir"]?.try { |c| expand_tilde(c) }
      stdin_data = @params["stdin"]?

      # Change directory if requested
      original_dir = Dir.current
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
        # Restore directory
        Dir.cd(original_dir) if chdir

        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to execute command: #{ex.message}",
          stderr: ex.message
        )
      end

      # Restore directory
      Dir.cd(original_dir) if chdir

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
            # Unquoted backslash-escape (shlex/POSIX shell semantics,
            # not just a literal character) - the char immediately
            # after is taken verbatim and the backslash itself dropped.
            # Real Ansible's command module parses `cmd:` the same way
            # (Python's shlex.split). Found via konstruktoid-hardening's
            # own `find ... -exec aa-enforce {} \;` - without this, the
            # final argv token was the two characters `\;` instead of
            # find's actual required terminator `;`, and find rejected
            # it outright ("missing argument to `-exec'"). A trailing
            # backslash with nothing after it is kept as a literal
            # backslash rather than silently dropped.
            if i + 1 < chars.size
              current << chars[i + 1]
              i += 1
            else
              current << char
            end
            started = true
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
