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
# Parameters:
#   cmd (required) or _raw_params (required, exactly one of the two):
#     "<path> [args...]" - `cmd:` is the explicit dict-form spelling,
#     `_raw_params` is what the free-form/bare-string task arg arrives
#     as. Real script.py's own action-plugin argument_spec declares
#     required_one_of=[['_raw_params', 'cmd']] and
#     mutually_exclusive=[['_raw_params', 'cmd']] - giving neither fails
#     with "one of the following is required: _raw_params, cmd", giving
#     both with "parameters are mutually exclusive: _raw_params|cmd".
#   creates/removes (optional): idempotency guards, same as command:
#   chdir (optional): directory to run from
#   executable (optional): interpreter to invoke the script with
#     (e.g. "/usr/bin/python3") instead of executing it directly
#
# Always reports changed: true (no idempotency concept of its own, same
# as command:/shell:) unless creates:/removes: skips the run entirely.

require "json"
require "../src/krikri/base_plugin"

module Krikri
  class ScriptPlugin < BasePlugin
    def execute : PluginResult
      if @params["cmd"]? && @params["_raw_params"]?
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: _raw_params|cmd")
      end

      cmd = @params["cmd"]? || @params["_raw_params"]?
      return PluginResult.new(changed: false, failed: true, msg: "one of the following is required: _raw_params, cmd") unless cmd

      parts = cmd.strip.split(/\s+/, 2)
      script_path = parts[0]?
      return PluginResult.new(changed: false, failed: true, msg: "one of the following is required: _raw_params, cmd") if script_path.nil? || script_path.empty?
      args = parts[1]?

      if skip = skip_reason
        return skip
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
    private def cleanup : Nil
      return unless true?(@params["__cleanup_after_script"]?)
      script_path = (@params["cmd"]? || @params["_raw_params"]? || "").strip.split(/\s+/, 2).first?
      remote_exec("rm -f #{shell_quote(script_path)}") if script_path
    end

    # Same real-Ansible shape as command:/shell: - an ordinary "ok"
    # result (changed: false), never a task-level "skipping:" (this
    # codebase's own `skipped: true` used to divert it into the
    # `skipped=` recap bucket instead of `ok=`, a real divergence in
    # its own right - live-verified against ansible-core 2.19.4), and
    # a real GLOB pattern, not a literal path (`path_or_glob_exists?`,
    # see that helper's own comment).
    private def skip_reason : PluginResult?
      if creates = @params["creates"]?
        if path_or_glob_exists?(expand_tilde(creates))
          return PluginResult.new(changed: false, failed: false, msg: "Did not run command since '#{creates}' exists", stdout: "skipped, since #{creates} exists")
        end
      end

      if removes = @params["removes"]?
        unless path_or_glob_exists?(expand_tilde(removes))
          return PluginResult.new(changed: false, failed: false, msg: "Did not run command since '#{removes}' does not exist", stdout: "skipped, since #{removes} does not exist")
        end
      end

      nil
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ScriptPlugin.new(config)
plugin.run
