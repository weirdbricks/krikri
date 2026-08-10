#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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
    property check_mode : Bool
    property diff_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
      @diff_mode = is_true?(@params["diff_mode"]?)
    end

    def execute : PluginResult
      # Get command (supports both direct string and 'cmd' parameter)
      cmd = @params["_raw_params"]? || @params["cmd"]?
      unless cmd
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: cmd"
        )
      end

      # Check creates parameter (idempotency)
      if creates = @params["creates"]?
        if remote_file_exists?(creates)
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Skipped: #{creates} already exists"
          )
        end
      end

      # Check removes parameter (conditional execution)
      if removes = @params["removes"]?
        unless remote_file_exists?(removes)
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Skipped: #{removes} does not exist"
          )
        end
      end

      # Shell commands don't support check mode (Ansible behavior)
      if @check_mode
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "Skipped: shell module does not support check mode"
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
    private def is_true?(value) : Bool
      return false if value.nil?
      value_str = value.to_s.downcase
      value_str == "true" || value_str == "yes" || value_str == "1"
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::ShellPlugin.new(config)
plugin.run
