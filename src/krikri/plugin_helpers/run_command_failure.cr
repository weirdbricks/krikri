module Krikri
  module PluginHelpers
    # Real AnsibleModule.run_command's two failure shapes, for plugins
    # that shell out the way real modules do (module.run_command with
    # check_rc):
    #
    # 1. An exec that never started (missing or unexecutable binary)
    #    surfaces the caught OSError: rc=errno, empty stdout/stderr,
    #    msg "Error executing command.", the cleaned (space-joined)
    #    command string, and the exception text "[Errno N] <reason>:
    #    b'<exe>'". Real 2.19 composes the display header as
    #    "<msg>: <exception str>" from that exception field while the
    #    dumped result keeps the bare msg - krikri's result display
    #    mirrors that whenever a failed result carries a real
    #    `exception` value (anything but the "(traceback unavailable)"
    #    placeholder).
    # 2. A started exec that exited non-zero under check_rc=True fails
    #    with msg=stderr.rstrip() plus cmd/rc/stdout/stderr (and the
    #    _lines splits the display adds).
    #
    # The errno/reason pairs come from the execve failure the module's
    # subprocess.Popen would see: ENOENT (2, "No such file or
    # directory") for a missing file, EACCES (13, "Permission denied")
    # for an existing non-executable one.
    module RunCommandFailure
      extend self

      # exec never started (OSError shape). *errno*/*reason* describe the
      # execve failure; *exe* is the binary path exactly as the module
      # passed it (the b'...' quoting is Python's own errno repr).
      def exec_failure(exe : String, errno : Int32, reason : String, cmd : String) : Krikri::PluginResult
        res = Krikri::PluginResult.new(
          changed: false, failed: true, msg: "Error executing command.",
          cmd: cmd, rc: errno, stdout: "", stderr: "",
          stdout_lines: [] of String, stderr_lines: [] of String,
        )
        res.extra["exception"] = JSON::Any.new("[Errno #{errno}] #{reason}: b'#{exe}'")
        res
      end

      # ENOENT convenience of #exec_failure.
      def not_found(exe : String, cmd : String) : Krikri::PluginResult
        exec_failure(exe, 2, "No such file or directory", cmd)
      end

      # EACCES convenience of #exec_failure.
      def permission_denied(exe : String, cmd : String) : Krikri::PluginResult
        exec_failure(exe, 13, "Permission denied", cmd)
      end

      # Non-zero exit under check_rc=True (the sanitized stderr becomes
      # the msg).
      def nonzero_exit(cmd : String, rc : Int32, stdout : String, stderr : String) : Krikri::PluginResult
        Krikri::PluginResult.new(
          changed: false, failed: true, msg: stderr.rstrip,
          cmd: cmd, rc: rc, stdout: stdout, stderr: stderr,
          stdout_lines: [] of String, stderr_lines: [] of String,
        )
      end

      # Real the real module get_bin_path's ValueError
      # when the binary is nowhere to be found. Real surfaces it as a
      # bare fail_json-style msg (live-verified vs 2.19.11: the fatal
      # msg carries no "Task failed:" chain prefix).
      def bin_path_missing(name : String, searched_paths : String) : String
        %(Failed to find required executable "#{name}" in paths: #{searched_paths})
      end

      # True when *exe* (an executable override param, used VERBATIM like
      # real's `executable.split(" ")` - never a PATH search) would fail
      # execve. Returns the errno/reason pair it fails with, or nil when
      # a real subprocess would find and exec it.
      def exec_check(exe : String) : {Int32, String}?
        if exe.includes?("/")
          return {2, "No such file or directory"} unless File.exists?(exe)
          # execve on a directory fails with EACCES even when the dir bits
          # allow traversal - real's npm `_exec` runs right after its own
          # os.makedirs(path), so an executable:/path pointing at the
          # freshly-created path DIRECTORY surfaces [Errno 13]
          # (live-verified vs 2.19.11, npm #184).
          return {13, "Permission denied"} if File.directory?(exe)
          return {13, "Permission denied"} unless File::Info.executable?(exe)
          nil
        else
          # A bare name goes through the execvpe PATH search.
          return {2, "No such file or directory"} unless Process.find_executable(exe)
          nil
        end
      end
    end
  end
end
