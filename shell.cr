#!/usr/bin/env crystal

require "json"
require "./base_plugin"

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
      
      # Execute with specified shell
      shell_cmd = "#{executable} -c #{shell_escape(full_cmd)}"
      result = remote_exec(shell_cmd)
      
      # Build diff data if diff mode enabled
      diff_data = nil
      if @diff_mode
        diff_hash = {
          "prepared" => "$ #{cmd}\n#{result[:stdout]}"
        }
        diff_data = JSON.parse(diff_hash.to_json)
      end
      
      # Shell commands always report changed (Ansible behavior)
      # unless they were skipped by creates/removes
      PluginResult.new(
        changed: true,
        failed: result[:exit_code] != 0,
        msg: result[:exit_code] == 0 ? "Command executed successfully" : "Command failed",
        stdout: result[:stdout],
        stderr: result[:stderr],
        exit_code: result[:exit_code],
        diff: diff_data
      )
    end
    
    # Helper to shell-escape commands
    private def shell_escape(str : String) : String
      # Use single quotes and escape any single quotes in the string
      "'" + str.gsub("'", "'\\''") + "'"
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
