#!/usr/bin/env crystal

# tempfile module (ansible.builtin.tempfile) - creates a temporary file or
# directory on the target and returns its path. Always reports changed:
# true (there is no idempotency concept - a fresh, uniquely-named path is
# created on every run, matching real Ansible's own tempfile.mkstemp/
# mkdtemp-backed module).
#
# Parameters:
#   state (optional): "file" (default) or "directory"
#   path (optional): parent dir to create the tempfile/dir under (defaults
#     to the target's own tmp dir, same as Python's tempfile module default)
#   prefix (optional): filename prefix (default "ansible.")
#   suffix (optional): filename suffix (default "")

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class TempfilePlugin < BasePlugin
    def execute : PluginResult
      state = normalized_state
      unless {"file", "directory"}.includes?(state)
        return PluginResult.new(changed: false, failed: true, msg: "state must be 'file' or 'directory', got '#{state}'")
      end

      dir = target_dir
      if dir && !remote_dir_exists?(dir)
        return PluginResult.new(changed: false, failed: true, msg: "could not find or access the requested directory: #{dir}")
      end

      result = remote_exec(mktemp_command(state, dir))
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to create temporary #{state}: #{result[:stderr].strip}")
      end

      path = result[:stdout].strip
      PluginResult.new(changed: true, failed: false, msg: "", path: path, state: state)
    end

    private def normalized_state : String
      state = @params["state"]?
      state = "file" if state.nil? || state.empty?
      state
    end

    private def target_dir : String?
      @params["path"]?.try { |pth| expand_tilde(pth) }
    end

    private def mktemp_command(state : String, dir : String?) : String
      prefix = @params["prefix"]?
      prefix = "ansible." if prefix.nil? || prefix.empty?
      suffix = @params["suffix"]? || ""
      template = "#{prefix}XXXXXX#{suffix}"
      full_template = dir ? "#{dir.chomp('/')}/#{template}" : template
      mktemp_flag = state == "directory" ? "-d " : ""

      dir ? "mktemp #{mktemp_flag}#{shell_quote(full_template)}" : "mktemp #{mktemp_flag}--tmpdir #{shell_quote(template)}"
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::TempfilePlugin.new(config)
plugin.run
