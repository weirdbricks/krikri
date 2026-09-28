require "socket"
require "../minitest_helper"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/plugin_manager"

# Regression specs for the solo daemon path's double-execution guard.
#
# PluginManager's solo daemon call used to rescue ANY daemon failure and
# fall through to the one-shot (fork-a-fresh-process) transport - which
# re-executes the module from scratch. For a request that was SENT but
# whose response was lost or unparseable, the module may already have
# run inside the daemon, so that fallback double-applies non-idempotent
# actions (a bare command:, an append, an email). The transport now
# classifies failures by how far the request got
# (SSHManager::DaemonDispatchUnknownError for "sent, response unusable")
# and the caller fails the task instead of re-running it. Failures that
# provably mean "nothing dispatched" (a daemon this call spawned itself
# never came up, a broken pipe on the write) keep the raw exception and
# the fallback.
#
# The daemon used here is a LOCAL fake process (a bash one-liner speaking
# the same length-prefixed frame protocol) seeded into SSHManager's
# daemon cache via a spec seam - no SSH, no real host.
private module DaemonHostScope
  @@host_mutex = Mutex.new
  @@host_by_fiber = {} of Fiber => String

  # Per-test unique fake host: every test seeds and then clears the daemon
  # cache entry for its host, so a shared host would let one test's teardown
  # delete the cache entry another concurrent test is mid-dispatch on.
  def self.host : String
    @@host_mutex.synchronize do
      @@host_by_fiber[Fiber.current] ||= "daemon-dispatch-#{Random::Secure.hex(4)}.invalid"
    end
  end
end

private def spec_host : String
  DaemonHostScope.host
end

private SPEC_USER   = "spec-user"
private SPEC_PORT   = nil
private SPEC_BECOME = nil

private def seed_daemon(process : Process) : Nil
  Krikri::SSHManager.seed_daemon_process_for_spec(spec_host, SPEC_USER, SPEC_PORT, SPEC_BECOME, process)
end

private def clear_daemon : Nil
  Krikri::SSHManager.clear_daemon_for_spec(spec_host, SPEC_USER, SPEC_PORT, SPEC_BECOME)
end

private def fake_daemon(command : String) : Process
  Process.new("/bin/bash", ["-c", command],
    input: Process::Redirect::Pipe,
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Close)
end

# A length-prefixed frame of *payload*, base64-encoded so it can travel
# inside a shell command line as plain text.
private def framed_b64(payload : String) : String
  io = IO::Memory.new
  io.write_bytes(payload.bytesize.to_u32, IO::ByteFormat::BigEndian)
  io.print(payload)
  Base64.strict_encode(io.to_s)
end

private def spec_send(timeout : Int32 = 5) : JSON::Any
  Krikri::SSHManager.daemon_send(spec_host, SPEC_USER, SPEC_PORT, "/var/tmp/krikri/command",
    "command", JSON.parse(%({"params": {"_raw_params": "echo hi"}})), timeout: timeout)
end

describe "solo daemon path dispatch-vs-response-lost classification" do
  it "raises DaemonDispatchUnknownError when a CACHED daemon's response never arrives" do
    seed_daemon(fake_daemon("sleep 5"))
    begin
      ex = assert_raises(Krikri::SSHManager::DaemonDispatchUnknownError) do
        spec_send(timeout: 1)
      end
      ex.message.to_s.must_include("response was lost")
      ex.message.to_s.must_include("command")
    ensure
      clear_daemon
    end
  end

  it "raises DaemonDispatchUnknownError when a CACHED daemon answers with garbage (unframeable bytes)" do
    # Echoes raw bytes with no length prefix, then stays alive so the
    # write cannot race its exit: the controller reads 'junk...' as a
    # u32 length prefix far past the frame cap.
    seed_daemon(fake_daemon("echo junkjunkjunkjunkjunk; sleep 5"))
    begin
      ex = assert_raises(Krikri::SSHManager::DaemonDispatchUnknownError) do
        spec_send(timeout: 5)
      end
      ex.message.to_s.must_include("response was lost")
    ensure
      clear_daemon
    end
  end

  it "raises DaemonDispatchUnknownError when a CACHED daemon answers with a framed but unparseable response" do
    seed_daemon(fake_daemon("echo #{framed_b64("not-json")} | base64 -d; sleep 5"))
    begin
      ex = assert_raises(Krikri::SSHManager::DaemonDispatchUnknownError) do
        spec_send(timeout: 5)
      end
      ex.message.to_s.must_include("not valid JSON")
    ensure
      clear_daemon
    end
  end

  it "still returns a parsed result from a healthy CACHED daemon" do
    seed_daemon(fake_daemon("echo #{framed_b64(%({"changed": true, "rc": 0}))} | base64 -d; sleep 5"))
    begin
      result = spec_send(timeout: 5)
      result["changed"].as_bool.must_equal(true)
      result["rc"].as_i.must_equal(0)
    ensure
      clear_daemon
    end
  end

  it "re-raises a raw (non-DaemonDispatchUnknownError) exception when the daemon was spawned by THIS call and never came up" do
    # The host is the per-test .invalid fake: ssh dials it, fails to
    # resolve/connect, exits - the controller's read hits
    # EOF with a daemon that was never proven alive, which must stay in
    # the raw-exception class so the caller's one-shot fallback (and its
    # UNREACHABLE handling) still applies.
    ex = Exception.new("no exception raised")
    raised = true
    begin
      spec_send(timeout: 5)
      raised = false
    rescue e
      ex = e
    end
    raised.must_equal(true)
    ex.class.name.wont_equal("Krikri::SSHManager::DaemonDispatchUnknownError")
  end
end

describe "PluginManager.daemon_dispatch_unknown_result" do
  it "builds a failed _connection_failure result that says the task was not re-executed" do
    ex = Krikri::SSHManager::DaemonDispatchUnknownError.new("daemon request for 'command' was sent but its response was lost (IO::EOFError: EOF)")
    result = Krikri::PluginManager.daemon_dispatch_unknown_result(ex)
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["_connection_failure"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("NOT re-executed")
    result["msg"].as_s.must_include("may already have run")
  end
end
