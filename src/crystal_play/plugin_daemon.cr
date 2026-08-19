require "json"

module CrystalPlay
  # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #15 - the persistent
  # remote executor. Today's per-task remote path forks a local `ssh`
  # client, a remote `bash -s`, and `exec`s a fresh plugin process for
  # EVERY task (`PluginManager.execute_remote_plugin`) - real work
  # already banked (ControlMaster reuse, task batching, the fat plugin
  # binary) hasn't removed that per-task fork/exec cost. This module is
  # the remote HALF of the fix: started via `<fat-plugin> --daemon`
  # (see `build.sh`'s generated dispatcher), it stays resident over ONE
  # long-lived SSH session and serves every subsequent eligible task for
  # that host as a plain read+write on an already-open pipe - no new
  # process on either end. The controller half lives in
  # `ssh_manager.cr`'s `daemon_send`.
  #
  # Deliberately opt-in and narrowly scoped - see this class's own
  # design notes in SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #15 for
  # what's out of scope in this first landing (become:, batching,
  # remote async:, vars-context residency). Nothing here changes
  # default behavior: this module is only ever invoked by `--daemon`,
  # which nothing reaches unless `--persistent-daemon` was passed on the
  # controller.
  module PluginDaemon
    # 4-byte big-endian length prefix per message, not newline-delimited
    # framing - real `to_json` output never contains a raw unescaped
    # newline (JSON string encoding always escapes control characters),
    # so a delimiter would also technically work, but a true byte-count
    # prefix doesn't lean on that invariant holding forever. Symmetric
    # on both directions: a request and a response are framed the exact
    # same way.
    private def self.read_frame(io : IO) : Bytes
      length = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      bytes = Bytes.new(length)
      io.read_fully(bytes)
      bytes
    end

    private def self.write_frame(io : IO, payload : String) : Nil
      bytes = payload.to_slice
      io.write_bytes(bytes.size.to_u32, IO::ByteFormat::BigEndian)
      io.write(bytes)
      io.flush
    end

    # Serves requests off STDIN/STDOUT until STDIN closes (the
    # controller closing its write end of the pipe - see
    # `SSHManager.close_all_daemons` - is the clean-shutdown signal,
    # mirroring the one-shot path's own `STDIN.gets_to_end`-until-EOF
    # termination; no explicit "goodbye" message needed). Each request
    # is `{"module": "<simple plugin name>", "config": <original task
    # config, same shape #execute_remote_plugin already builds>}`; the
    # response is the *dispatch block's* raw return value (the same
    # JSON String `BasePlugin#run_and_capture` already produces) written
    # back framed, unchanged - callers on the controller side get
    # exactly the plugin's own JSON result, nothing wrapped around it.
    #
    # One request in flight at a time, by construction: a single SSH
    # session/pipe pair serves exactly one host's tasks, and this
    # codebase's own `--forks` model runs a given host's own tasks
    # sequentially on one fiber (verified directly - `executor.cr`'s
    # `run_task_for_hosts_in_parallel` spawns one fiber PER HOST, not
    # per task) - so there is never a second request racing this one on
    # the same daemon connection, no correlation ID needed.
    def self.serve(& : String, JSON::Any -> String) : Nil
      loop do
        frame = read_frame(STDIN)
        request = JSON.parse(String.new(frame))
        result = yield request["module"].as_s, request["config"]
        write_frame(STDOUT, result)
      end
    rescue IO::EOFError
      # STDIN closed - clean shutdown.
    end
  end
end
