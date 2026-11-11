require "../minitest_helper"
require "digest/md5"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/host"

# Issue #1158: after a /var/tmp sweep wiped the TARGET's plugin cache
# while the controller-side plugin-state record still said the binaries
# were present, the whole run fell back to per-task one-shot ssh (~2x
# slower on a real host) instead of re-uploading and continuing on the
# daemon path. The daemon spawn handshake had failed against the very
# binary that was missing and SSHManager.spawn_daemon stamped the
# connection permanently daemon-less, and the missing-binary recovery
# re-uploaded the binary but never dropped that stamp - so the daemon
# never got another attempt even though it would have started fine.
#
# The two sides of the fix are pinned here: SSHManager.
# clear_daemon_failures (the stamp drops for EVERY become key on the
# connection, and only for that connection) and PluginManager.
# drop_stale_plugin_beliefs (the recovery entry point that must drop it
# alongside the other stale "the binary is there" records), plus the
# dispatch leg the post-recovery retry rides (try_daemon_dispatch).
#
# The daemon is a LOCAL fake process speaking the framed protocol
# (daemon_dispatch_unknown_test.cr's own pattern), seeded into
# SSHManager's daemon cache through the spec seam - no SSH, no host.

private module RecoverScope
  @@host_mutex = Mutex.new
  @@host_by_fiber = {} of Fiber => String

  # Per-test unique fake host: every test stamps and then clears its own
  # daemon-table keys, so a shared host would let one test's teardown
  # delete a key another concurrent test is mid-dispatch on.
  def self.host : String
    @@host_mutex.synchronize do
      @@host_by_fiber[Fiber.current] ||= "daemon-recover-#{Random::Secure.hex(4)}.invalid"
    end
  end
end

private def spec_host : String
  RecoverScope.host
end

private def fake_daemon(command : String) : Process
  Process.new("/bin/bash", ["-c", command],
    input: Process::Redirect::Pipe,
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Close)
end

private def dead_process : Process
  process = Process.new("/bin/sh", ["-c", "exit 0"],
    input: Process::Redirect::Pipe,
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Close)
  process.wait
  process
end

# A length-prefixed frame of *payload*, base64-encoded so it can travel
# inside a shell command line as plain text.
private def framed_b64(payload : String) : String
  io = IO::Memory.new
  io.write_bytes(payload.bytesize.to_u32, IO::ByteFormat::BigEndian)
  io.print(payload)
  Base64.strict_encode(io.to_s)
end

# Drives MAX_DAEMON_FAILURES consecutive dispatch failures for one
# daemon key - the exact consecutive-failure pattern the circuit
# breaker counts - by seeding an already-dead process as the cached
# daemon: the frame write hits a closed pipe, daemon_send records the
# failure and evicts it. Returns the connection sig the key was
# stamped under (the same one daemon_send computed), so callers can
# clear or probe exactly that key.
private def stamp_failures(host : String, user : String, port : Int32?, become_user : String?, identity_file : String? = nil, extra_args : Array(String) = [] of String) : String
  sig = Krikri::SSHManager.connection_sig(identity_file, extra_args, nil)
  Krikri::SSHManager::MAX_DAEMON_FAILURES.times do
    Krikri::SSHManager.seed_daemon_process_for_spec(host, user, port, become_user, dead_process, sig)
    raised = false
    begin
      Krikri::SSHManager.daemon_send(host, user, port, "/var/tmp/krikri/command", "command",
        JSON.parse(%({"params": {"_raw_params": "echo hi"}})),
        identity_file: identity_file, become_user: become_user, extra_args: extra_args)
    rescue
      raised = true
    end
    raised.must_equal(true, "a dispatch against an already-dead daemon must fail and count against the breaker")
  end
  Krikri::SSHManager.daemon_unavailable?(host, user, port, become_user, sig).must_equal(true)
  sig
end

private def clear_key(host : String, user : String, port : Int32?, become_user : String?, sig : String) : Nil
  Krikri::SSHManager.clear_daemon_for_spec(host, user, port, become_user, sig)
end

describe "SSHManager.clear_daemon_failures (issue #1158)" do
  it "drops the failure stamp of every become key on the connection" do
    # One connection holds a no-become daemon and a become_user daemon
    # (SSHManager's own keying); a wiped target kills the handshake of
    # whichever is attempted first, and the run must get BOTH back - the
    # stamp is about the connection's binaries being gone, not about a
    # particular user.
    host = spec_host
    user = "spec-user"
    begin
      sig = stamp_failures(host, user, nil, nil)
      stamp_failures(host, user, nil, "deploy")

      Krikri::SSHManager.clear_daemon_failures(host, user, nil, sig)

      Krikri::SSHManager.daemon_unavailable?(host, user, nil, nil, sig).must_equal(false)
      Krikri::SSHManager.daemon_unavailable?(host, user, nil, "deploy", sig).must_equal(false)
    ensure
      Krikri::SSHManager.clear_daemon_failures(host, user, nil)
    end
  end

  it "leaves other connections' stamps in place" do
    # Clearing is per (host, user, port, options): a second connection
    # that genuinely cannot start a daemon (sudo refused, no --daemon
    # entry point) keeps its own breaker and its one-handshake-per-run
    # bound.
    host = spec_host
    begin
      kept = stamp_failures(host, "other-user", nil, nil)
      dropped = stamp_failures(host, "spec-user", nil, nil, extra_args: ["-o", "BatchMode=yes"])

      Krikri::SSHManager.clear_daemon_failures(host, "spec-user", nil, dropped)

      Krikri::SSHManager.daemon_unavailable?(host, "spec-user", nil, nil, dropped).must_equal(false)
      Krikri::SSHManager.daemon_unavailable?(host, "other-user", nil, nil, kept).must_equal(true)
    ensure
      Krikri::SSHManager.clear_daemon_failures(host, "other-user", nil)
      Krikri::SSHManager.clear_daemon_failures(host, "spec-user", nil, Krikri::SSHManager.connection_sig(nil, ["-o", "BatchMode=yes"], nil))
    end
  end
end

describe "PluginManager.try_daemon_dispatch (issue #1158)" do
  serial! # flips the engine-global daemon_enabled setting

  before_each do
    Krikri::PluginManager.daemon_enabled = true
  end

  after_each do
    Krikri::PluginManager.daemon_enabled = false
  end

  def spec_conn : {Krikri::Host, Hash(String, JSON::Any), Krikri::ConnectionSettings}
    host = Krikri::Host.new(spec_host, "spec-user", nil)
    vars = {} of String => JSON::Any
    {host, vars, Krikri::ConnectionSettings.resolve(host, vars)}
  end

  def seed_for(conn : Krikri::ConnectionSettings, become_user : String?, process : Process) : Nil
    Krikri::SSHManager.seed_daemon_process_for_spec(conn.conn_host, conn.user, conn.port, become_user, process,
      Krikri::SSHManager.connection_sig(conn.identity_file, conn.ssh_extra_options, conn.password))
  end

  it "returns the module's own result from a healthy daemon" do
    host, vars, conn = spec_conn
    seed_for(conn, nil, fake_daemon("echo #{framed_b64(%({"changed": true, "rc": 0}))} | base64 -d; sleep 5"))
    begin
      if result = Krikri::PluginManager.try_daemon_dispatch(
           "command", %({"params": {"_raw_params": "echo hi"}}), host, vars, false, nil, nil, nil, conn)
        result["changed"].as_bool.must_equal(true)
        result["rc"].as_i.must_equal(0)
      else
        flunk("expected the daemon leg to return the module's result")
      end
    ensure
      Krikri::SSHManager.clear_daemon_for_spec(conn.conn_host, conn.user, conn.port, nil)
    end
  end

  it "fails the task instead of falling back when a dispatched request's response is lost" do
    # The fallback re-EXECUTES the module, so the post-recovery retry
    # must take this same verdict too: a request that reached the daemon
    # must never be silently re-run over the one-shot path.
    host, vars, conn = spec_conn
    seed_for(conn, nil, fake_daemon("sleep 1"))
    begin
      if result = Krikri::PluginManager.try_daemon_dispatch(
           "command", %({"params": {"_raw_params": "echo hi"}}), host, vars, false, nil, nil, nil, conn)
        result["unreachable"]?.try(&.as_bool?).must_equal(true)
      else
        flunk("expected the lost-response verdict instead of a fall-through")
      end
    ensure
      Krikri::SSHManager.clear_daemon_for_spec(conn.conn_host, conn.user, conn.port, nil)
    end
  end

  it "returns nil (caller falls back) when the daemon never came up" do
    # Nothing dispatched - the raw-exception class keeps the one-shot
    # fallback available, exactly what the post-recovery retry relies on
    # when its fresh spawn still cannot start.
    host, vars, conn = spec_conn
    seed_for(conn, nil, dead_process)
    begin
      Krikri::PluginManager.try_daemon_dispatch(
        "command", %({"params": {"_raw_params": "echo hi"}}), host, vars, false, nil, nil, nil, conn)
        .must_be_nil
    ensure
      Krikri::SSHManager.clear_daemon_for_spec(conn.conn_host, conn.user, conn.port, nil)
    end
  end

  it "skips the daemon entirely once the circuit breaker is tripped" do
    host, vars, conn = spec_conn
    begin
      stamp_failures(conn.conn_host, conn.user, conn.port, nil,
        identity_file: conn.identity_file, extra_args: conn.ssh_extra_options)

      Krikri::PluginManager.try_daemon_dispatch(
        "command", %({"params": {"_raw_params": "echo hi"}}), host, vars, false, nil, nil, nil, conn)
        .must_be_nil
    ensure
      Krikri::SSHManager.clear_daemon_failures(conn.conn_host, conn.user, conn.port)
    end
  end

  it "never takes the daemon for a timeout: task" do
    # Its in-flight module cannot be killed without killing the daemon
    # (see the method's own comment) - the retry after a missing binary
    # keeps the one-shot exec for these too.
    host, vars, conn = spec_conn
    begin
      Krikri::PluginManager.try_daemon_dispatch(
        "command", %({"params": {"_raw_params": "echo hi"}}), host, vars, false, nil, nil, 30_i64, conn)
        .must_be_nil
    ensure
      Krikri::SSHManager.clear_daemon_for_spec(conn.conn_host, conn.user, conn.port, nil)
    end
  end

  it "never takes the daemon while the daemon mode is off" do
    Krikri::PluginManager.daemon_enabled = false
    host, vars, conn = spec_conn
    begin
      Krikri::PluginManager.try_daemon_dispatch(
        "command", %({"params": {"_raw_params": "echo hi"}}), host, vars, false, nil, nil, nil, conn)
        .must_be_nil
    ensure
      Krikri::SSHManager.clear_daemon_for_spec(conn.conn_host, conn.user, conn.port, nil)
    end
  end
end

describe "PluginManager.drop_stale_plugin_beliefs (issue #1158)" do
  serial! # writes the plugin-state cache file and mutates engine caches

  it "drops the daemon circuit breaker's stamp along with the plugin records" do
    previous = ENV["XDG_CACHE_HOME"]?
    dir = PluginSpecHelper.tmp_path("drop-stale-beliefs-cache")
    Dir.mkdir_p(dir)
    ENV["XDG_CACHE_HOME"] = dir
    Krikri::PluginManager.clear_cache
    host = Krikri::Host.new(spec_host, "spec-user", nil)
    vars = {} of String => JSON::Any
    conn = Krikri::ConnectionSettings.resolve(host, vars)
    begin
      sig = stamp_failures(conn.conn_host, conn.user, conn.port, nil,
        identity_file: conn.identity_file, extra_args: conn.ssh_extra_options)
      stamp_failures(conn.conn_host, conn.user, conn.port, "deploy",
        identity_file: conn.identity_file, extra_args: conn.ssh_extra_options)

      Krikri::PluginManager.drop_stale_plugin_beliefs(conn, ["command"])

      # The handshake that stamped these failed only because the binary
      # was missing - with the record that said "it is there" dropped,
      # the stamp has to go too or the daemon is never attempted again.
      Krikri::SSHManager.daemon_unavailable?(conn.conn_host, conn.user, conn.port, nil, sig).must_equal(false)
      Krikri::SSHManager.daemon_unavailable?(conn.conn_host, conn.user, conn.port, "deploy", sig).must_equal(false)
    ensure
      Krikri::SSHManager.clear_daemon_failures(conn.conn_host, conn.user, conn.port)
      Krikri::PluginManager.clear_cache
      previous ? (ENV["XDG_CACHE_HOME"] = previous) : ENV.delete("XDG_CACHE_HOME")
    end
  end

  it "invalidates the controller-side plugin-state record for the host" do
    previous = ENV["XDG_CACHE_HOME"]?
    dir = PluginSpecHelper.tmp_path("drop-stale-beliefs-cache")
    Dir.mkdir_p(dir)
    ENV["XDG_CACHE_HOME"] = dir
    Krikri::PluginManager.clear_cache
    begin
      skip "plugin binaries not built (run ./build.sh first)" unless File.exists?(File.join(PluginSpecHelper::PLUGINS_DIR, "command"))

      host = Krikri::Host.new(spec_host, "spec-user", nil)
      vars = {} of String => JSON::Any
      conn = Krikri::ConnectionSettings.resolve(host, vars)
      md5 = Digest::MD5.new.file(Krikri::PluginManager.local_plugin_path_for_spec("command", nil)).hexfinal
      Krikri::PluginManager.record_host_state_for_spec(conn.spec_key, {"command" => md5}, nil)
      Krikri::PluginManager.host_state_satisfies_for_spec?(conn.spec_key, ["command"]).must_equal(true)

      Krikri::PluginManager.drop_stale_plugin_beliefs(conn, ["command"])

      # A wrong belief must never survive into the next run's skip of
      # the verification round trip.
      Krikri::PluginManager.host_state_satisfies_for_spec?(conn.spec_key, ["command"]).must_equal(false)
    ensure
      Krikri::PluginManager.clear_cache
      previous ? (ENV["XDG_CACHE_HOME"] = previous) : ENV.delete("XDG_CACHE_HOME")
    end
  end
end
