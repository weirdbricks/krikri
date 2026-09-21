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

      # Partial check-mode support, mirroring real Ansible's script action
      # plugin (live-verified against ansible-core 2.19.11): with NO
      # creates:/removes: gate the task reports `skipping:` and the
      # script never runs ("Check mode is not supported for this
      # task."); WITH a gate the module's own gate logic runs even in
      # check mode - a holding gate reports `skipping:` with the
      # "matching creates/removes option" msg (the SAME skip the module
      # produces on an ordinary run, see skip_reason), while a passing
      # gate reports an ordinary changed: true would-have-run result
      # whose registered var carries ONLY {changed: true, failed: false}
      # (no msg/rc/stdout keys at all). The skip must still fire BEFORE
      # any remote chmod/exec side effect.
      if true?(@params["_ansible_check_mode"]?)
        if skip = skip_reason
          return skip
        end

        gated = @params.has_key?("creates") || @params.has_key?("removes")
        return PluginResult.new(
          changed: gated,
          failed: false,
          msg: gated ? "" : "Check mode is not supported for this task.",
          skipped: !gated
        )
      end

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

    # Real script.py's own gate (live-verified against ansible-core
    # 2.19.11, normal runs AND check mode alike): a holding gate is a
    # SKIPPED result with the "matching creates/removes option" msg -
    # the recap books it in skipped=, unlike command:/shell:'s
    # ordinary-ok gate verdict ("Did not run command since ...", NOT
    # skipped - that command-style msg/shape was this plugin's own
    # borrow and a real divergence). Same shape check mode's holding
    # gate reports, so both paths share this one method.
    private def skip_reason : PluginResult?
      if creates = @params["creates"]?
        if path_or_glob_exists?(expand_tilde(creates))
          return PluginResult.new(changed: false, failed: false, msg: "#{creates} exists, matching creates option", skipped: true)
        end
      end

      if removes = @params["removes"]?
        unless path_or_glob_exists?(expand_tilde(removes))
          return PluginResult.new(changed: false, failed: false, msg: "#{removes} does not exist, matching removes option", skipped: true)
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
