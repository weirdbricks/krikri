#!/usr/bin/env crystal

# script module (ansible.builtin.script) - runs a local (controller-side)
# script on the target. TaskExecutor#stage_script_src does the
# controller->target transfer before this plugin ever runs (this plugin
# always sees `cmd` already rewritten to a path that exists wherever this
# process is actually executing - the remote target for an SSH host, the
# controller itself for a local connection) - same split of
# responsibility as unarchive's stage_unarchive_remote_src/copy's
# stage_large_copy_source.
#
# Parameters (all via the free-form `cmd`/bare-string task arg, same as
# command:/shell: - RAW_COMMAND_MODULES strips creates/removes/chdir/
# executable off the trailing end before this plugin ever sees `cmd`):
#   cmd (required): "<path> [args...]"
#   creates/removes (optional): idempotency guards, same as command:
#   chdir (optional): directory to run from
#   executable (optional): interpreter to invoke the script with
#     (e.g. "/usr/bin/python3") instead of executing it directly
#
# Always reports changed: true (no idempotency concept of its own, same
# as command:/shell:) unless creates:/removes: skips the run entirely.

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class ScriptPlugin < BasePlugin
    def execute : PluginResult
      cmd = @params["cmd"]? || @params["_raw_params"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: cmd") unless cmd

      parts = cmd.strip.split(/\s+/, 2)
      script_path = parts[0]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: cmd") if script_path.nil? || script_path.empty?
      args = parts[1]?

      if creates = @params["creates"]?
        if remote_file_exists?(expand_tilde(creates))
          return PluginResult.new(changed: false, failed: false, msg: "skipped, since #{creates} exists", skipped: true)
        end
      end

      if removes = @params["removes"]?
        unless remote_file_exists?(expand_tilde(removes))
          return PluginResult.new(changed: false, failed: false, msg: "skipped, since #{removes} does not exist", skipped: true)
        end
      end

      unless remote_file_exists?(script_path)
        cleanup
        return PluginResult.new(changed: false, failed: true, msg: "the script #{script_path} does not exist on the target (transfer failed?)")
      end

      remote_exec("chmod +x #{shell_quote(script_path)}")

      chdir = @params["chdir"]?.try { |itm| expand_tilde(itm) }
      executable = @params["executable"]?

      invocation = executable ? "#{executable} #{shell_quote(script_path)}" : shell_quote(script_path)
      invocation += " #{args}" if args
      invocation = "cd #{shell_quote(chdir)} && #{invocation}" if chdir

      result = remote_exec(invocation)
      cleanup

      PluginResult.new(
        changed: true,
        failed: result[:exit_code] != 0,
        msg: result[:exit_code] == 0 ? "" : "non-zero return code",
        stdout: result[:stdout].rstrip("\r\n"),
        stderr: result[:stderr].rstrip("\r\n"),
        rc: result[:exit_code]
      )
    end

    # Removes the SCP-staged copy left behind by TaskExecutor#
    # stage_script_src (marker only set for a real remote connection - a
    # local-connection run points `cmd` straight at the real controller-
    # side script, never staged, and must not be deleted).
    private def cleanup
      return unless true?(@params["__cleanup_after_script"]?)
      script_path = (@params["cmd"]? || @params["_raw_params"]? || "").strip.split(/\s+/, 2).first?
      remote_exec("rm -f #{shell_quote(script_path)}") if script_path
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::ScriptPlugin.new(config)
plugin.run
