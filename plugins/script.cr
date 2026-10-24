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
require "../src/krikri/plugin_helpers/ansible_splitlines"
require "../src/krikri/plugin_helpers/script_pty_capture"

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

      # Partial check-mode support, mirroring Ansible's script action
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
          cleanup
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
        cleanup
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

      # Remote staging (executor-side) opts this run into a simulated
      # ssh -tt session: real's script action runs the staged file via
      # _low_level_execute_command with in_data=nil, so its ssh plugin
      # requests `-tt` (ssh.py: `if not in_data and sudoable and
      # use_tty: args = ('-tt', ...)`) and the remote shell gets ONE pty
      # on stdout AND stderr. Wrapping the invocation so one pipe carries
      # both streams reproduces that merge in true execution order; the
      # \n->\r\n translation and the client's own close notice are
      # applied to the capture below (ScriptPtyCapture's header carries
      # the live-verified evidence). A locally-run script takes neither:
      # real's LOCAL connection never forces a tty, capturing the two
      # streams separately - which the markerless path already does.
      # .presence (not truthiness): a blank marker must behave as "no
      # marker exists" rather than a pty merge against an empty address.
      remote_addr = @params["__script_ssh_addr"]?.presence
      if remote_addr
        invocation = "{ #{invocation}; } 2>&1"
      end

      result = remote_exec(invocation)
      cleanup

      # Real's script ACTION returns the module capture untouched - no
      # trailing-strip of its own (unlike the command MODULE's
      # strip_empty_ends: true default): live-verified 2.19.11 shows
      # local stdout/stderr keeping their final "\n" and the remote pty
      # keeping the trailing "\r\n". When the marker is present,
      # result[:stdout] is the 2>&1 ONE-stream capture: its \n->\r\n
      # rendered form ships as stdout, while the stdout lines come off
      # the raw capture - Python's str.splitlines on the CRLF text
      # (dropping both halves of each "\r\n") is byte-equal to
      # splitting the raw "\n" capture. The remote stderr is openssh's
      # own close notice alone (everything remote-side rode the pty into
      # stdout); its only lines entry drops the attached "\r\n" the way
      # str.splitlines would.
      if remote_addr
        stdout = PluginHelpers::ScriptPtyCapture.pty_stdout(result[:stdout])
        stderr = PluginHelpers::ScriptPtyCapture.connection_closed_stderr(remote_addr)
        stdout_lines = PluginHelpers::AnsibleSplitlines.split(result[:stdout])
        stderr_lines = [stderr.rstrip("\r\n")]
      else
        stdout = result[:stdout]
        stderr = result[:stderr]
        # Ansible 2.19.11 registered order (live-verified, `{{ r | to_json }}`):
        # rc, stdout, stdout_lines, stderr, stderr_lines, changed - the
        # executor's failed: false backfill lands after changed. The script
        # action plugin builds stdout_lines/stderr_lines itself (module-side
        # here), which both places them between stdout/stderr and changed
        # and stops the register-time lines augmentation from appending
        # them after `failed`.
        stdout_lines = PluginHelpers::AnsibleSplitlines.split(stdout)
        stderr_lines = PluginHelpers::AnsibleSplitlines.split(stderr)
      end
      PluginResult.new(
        changed: true,
        failed: result[:exit_code] != 0,
        msg: result[:exit_code] == 0 ? "" : "non-zero return code",
        stdout: stdout,
        stderr: stderr,
        rc: result[:exit_code],
        stdout_lines: stdout_lines,
        stderr_lines: stderr_lines,
        key_order: %w[rc stdout stdout_lines stderr stderr_lines changed]
      )
    end

    # Removes the staged copy left behind by TaskExecutor#
    # stage_script_src (marker only set for a real remote connection - a
    # local-connection run points `cmd` straight at the real controller-
    # side script, never staged, and must not be deleted). New-style
    # staging notes the whole per-task tmp dir (ansible's own action
    # removes the WRAPPED dir, not just the file), so the removed tree
    # is that dir. Old-style runs (only the file was noted) strip just
    # the file.
    private def cleanup : Nil
      return unless true?(@params["__cleanup_after_script"]?)
      # The whole per-task dir - ansible's script.py cleans self._shell
      # .tmpdir in its run()'s finally clause, not the file alone, so the
      # dir and its tree leave no trace either.
      tmp_dir = @params["__script_tmp_dir"]?
      if tmp_dir && !tmp_dir.empty?
        remote_exec("rm -rf #{shell_quote(tmp_dir)}")
        return
      end
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
          # Ansible 2.19.11 (live-verified): the script ACTION plugin's
          # short-circuit skip registers skipped, msg, changed - no failed
          # key (unlike a module-side skip, which the executor backfills).
          return PluginResult.new(changed: false, failed: false, msg: "#{creates} exists, matching creates option", skipped: true, key_order: %w[skipped msg changed])
        end
      end

      if removes = @params["removes"]?
        unless path_or_glob_exists?(expand_tilde(removes))
          return PluginResult.new(changed: false, failed: false, msg: "#{removes} does not exist, matching removes option", skipped: true, key_order: %w[skipped msg changed])
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
