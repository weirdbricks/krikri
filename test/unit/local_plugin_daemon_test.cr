require "../minitest_helper"
require "../../src/krikri/local_plugin_daemon"
require "../../src/krikri/plugin_manager"

# Specs for the LOCAL persistent plugin daemon (ansible_connection=local) -
# the ansible_connection=local analogue of the ssh daemon, mirroring
# SSHManager's daemon_send contract point for point:
#
# - same framed wire protocol, driven here against the REAL compiled
#   .fat-plugin --daemon binary (same spirit as plugin_daemon_test.cr);
# - same failure classification split by how far the request got: a
#   provably-undispatched failure (dead daemon, spawn failure) keeps the
#   raw exception so the caller's one-fork fallback stays safe, while a
#   lost response on an ALREADY-CACHED daemon raises
#   SSHManager::DaemonDispatchUnknownError (the module may already have
#   run - re-executing could double-apply a non-idempotent action);
# - same consecutive-failure circuit breaker (3 in a row = stop trying),
#   reset by any success;
# - same timeout-kill behavior (a timed-out request's daemon is torn down,
#   never left hung).

private module LocalDaemonSpecScope
  @@mutex = Mutex.new
  @@host_by_fiber = {} of Fiber => String

  # Per-test unique fake host name: every test seeds and clears its own
  # daemon cache entry, so concurrent tests (minitest -p 4) never share a
  # key - same pattern daemon_dispatch_unknown_test.cr uses for SSHManager.
  def self.host : String
    @@mutex.synchronize do
      @@host_by_fiber[Fiber.current] ||= "local-daemon-#{Random::Secure.hex(4)}.invalid"
    end
  end
end

private def spec_host : String
  LocalDaemonSpecScope.host
end

private def fat_binary : String
  File.join(PluginSpecHelper::PLUGINS_DIR, ".fat-plugin")
end

private def command_config(raw : String) : JSON::Any
  JSON.parse({
    "host"   => {"name" => spec_host, "user" => ENV["USER"]? || "root", "port" => 22},
    "vars"   => {"ansible_connection" => "local"},
    "params" => {"_raw_params" => raw},
  }.to_json)
end

private def spec_send(config : JSON::Any, timeout : Int32 = 10, plugin_path : String? = nil, become_user : String? = nil) : JSON::Any
  Krikri::LocalPluginDaemon.send(
    spec_host, "command", config,
    plugin_path || fat_binary,
    become_user: become_user, timeout: timeout
  )
end

private def seed_daemon(process : Process, become_user : String? = nil) : Nil
  Krikri::LocalPluginDaemon.seed_daemon_process_for_spec(spec_host, become_user, process)
end

private def clear_daemon(become_user : String? = nil) : Nil
  Krikri::LocalPluginDaemon.clear_daemon_for_spec(spec_host, become_user)
end

private def cached_process : Process?
  Krikri::LocalPluginDaemon.daemon_process_for_spec(spec_host, nil)
end

private def fake_daemon(command : String) : Process
  Process.new("/bin/bash", ["-c", command],
    input: Process::Redirect::Pipe,
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Close)
end

describe "LocalPluginDaemon argv construction" do
  it "runs the plugin binary directly with --daemon when no become_user is set" do
    argv = Krikri::LocalPluginDaemon.local_daemon_argv("/opt/plugins/command", nil, interactive: false)
    argv.must_equal(["/opt/plugins/command", "--daemon"])
  end

  it "wraps a become_user daemon in passwordless sudo -n, same flags as the one-shot local path" do
    argv = Krikri::LocalPluginDaemon.local_daemon_argv("/opt/plugins/command", "deploy", interactive: false)
    argv.must_equal(["-n", "-u", "deploy", "--", "/opt/plugins/command", "--daemon"])
  end

  it "uses sudo -S with an empty prompt when the escalation needs a password" do
    argv = Krikri::LocalPluginDaemon.local_daemon_argv("/opt/plugins/command", "deploy", interactive: true)
    argv.must_equal(["-S", "-p", "", "-u", "deploy", "--", "/opt/plugins/command", "--daemon"])
  end
end

describe "LocalPluginDaemon send against the real fat plugin" do
  it "spawns a resident daemon, serves a request, and REUSES the same process for the next request" do
    skip "fat plugin binary not built (run ./build.sh first)" unless File.exists?(fat_binary)

    begin
      first = spec_send(command_config("echo daemon-one"))
      first["stdout"].as_s.must_equal("daemon-one")
      first["rc"].as_i64.must_equal(0)

      process = cached_process
      process.nil?.must_equal(false)
      process.try(&.terminated?).must_equal(false)

      second = spec_send(command_config("echo daemon-two"))
      second["stdout"].as_s.must_equal("daemon-two")
      # The SAME resident process answered both requests - no re-spawn.
      cached_process.must_equal(process)
    ensure
      clear_daemon
    end
  end

  it "serves different modules over the same daemon, dispatching by request name" do
    skip "fat plugin binary not built (run ./build.sh first)" unless File.exists?(fat_binary)

    begin
      result = Krikri::LocalPluginDaemon.send(
        spec_host, "stat",
        JSON.parse({
          "host"   => {"name" => spec_host, "user" => ENV["USER"]? || "root", "port" => 22},
          "vars"   => {"ansible_connection" => "local"},
          "params" => {"path" => "/etc/hostname"},
        }.to_json),
        fat_binary
      )
      result["stat"]["exists"].as_bool.must_equal(true)
      # The daemon is still alive and can serve the original module again.
      spec_send(command_config("echo after-stat"))["stdout"].as_s.must_equal("after-stat")
    ensure
      clear_daemon
    end
  end

  it "does not leak one request's environment overlay or chdir into the next request on the same daemon" do
    skip "fat plugin binary not built (run ./build.sh first)" unless File.exists?(fat_binary)

    begin
      env_config = JSON.parse({
        "host"   => {"name" => spec_host, "user" => ENV["USER"]? || "root", "port" => 22},
        "vars"   => {"ansible_connection" => "local"},
        "params" => {"_raw_params" => "env"},
      }.to_json)
      env_config.as_h["params"].as_h["_environment"] = JSON::Any.new(%({"KRIKRI_DAEMON_SPEC_PROBE": "leak-me"}))
      marked = spec_send(env_config)
      marked["stdout"].as_s.includes?("KRIKRI_DAEMON_SPEC_PROBE=leak-me").must_equal(true)

      clean = spec_send(command_config("env"))
      clean["stdout"].as_s.includes?("KRIKRI_DAEMON_SPEC_PROBE").must_equal(false)

      chdir_config = JSON.parse({
        "host"   => {"name" => spec_host, "user" => ENV["USER"]? || "root", "port" => 22},
        "vars"   => {"ansible_connection" => "local"},
        "params" => {"_raw_params" => "pwd", "chdir" => "/etc"},
      }.to_json)
      spec_send(chdir_config)["stdout"].as_s.must_equal("/etc")

      # The next request on the SAME daemon sees the daemon process's own
      # cwd, not the previous request's chdir: / - the daemon's spawn cwd.
      after = spec_send(command_config("pwd"))
      (after["stdout"].as_s == "/etc").must_equal(false)
    ensure
      clear_daemon
    end
  end
end

describe "LocalPluginDaemon failure classification" do
  it "keeps the raw exception (fallback-safe) when a CACHED daemon is already dead - broken pipe on write" do
    dead = fake_daemon("exit 0")
    dead.wait
    seed_daemon(dead)
    begin
      error = assert_raises(Exception) do
        spec_send(command_config("echo never"))
      end
      # Raw exception, NOT the dispatched-but-lost classification: the
      # frame never went out in full, so the caller's fallback may safely
      # re-execute the module.
      error.is_a?(IO::Error).must_equal(true)
      error.class.wont_equal Krikri::SSHManager::DaemonDispatchUnknownError
      # The dead daemon was evicted; the failure was counted once.
      cached_process.must_be_nil
    ensure
      clear_daemon
    end
  end

  it "raises DaemonDispatchUnknownError when a CACHED daemon consumes the request but never responds" do
    # `sleep` never reads stdin (the frame write lands in the pipe buffer,
    # i.e. the request WAS dispatched) and never writes a response.
    silent = fake_daemon("sleep 5")
    seed_daemon(silent)
    begin
      ex = assert_raises(Krikri::SSHManager::DaemonDispatchUnknownError) do
        spec_send(command_config("echo lost"), timeout: 1)
      end
      ex.message.to_s.includes?("response was lost").must_equal(true)
      # The timed-out daemon was torn down, not left hung. SIGKILL
      # delivery is asynchronous, so poll briefly instead of asserting
      # the flag in the same instant the signal was sent.
      50.times do
        break if silent.terminated?
        sleep 10.milliseconds
      end
      silent.terminated?.must_equal(true)
      cached_process.must_be_nil
    ensure
      clear_daemon
    end
  end

  it "keeps the raw exception when the daemon IT SPAWNED never responds (fallback-safe, never-proven daemon)" do
    skip "fat plugin binary not built (run ./build.sh first)" unless File.exists?(fat_binary)

    # A plugin path that is NOT the fat plugin: a real binary that exits
    # immediately after spawn, so the daemon "never came up" - the failure
    # must stay the raw exception class (fallback-safe), never the
    # dispatched-but-lost classification, and evict the process.
    begin
      error = assert_raises(Exception) do
        spec_send(command_config("echo never"), timeout: 5, plugin_path: "/bin/true")
      end
      error.class.wont_equal Krikri::SSHManager::DaemonDispatchUnknownError
      cached_process.must_be_nil
    ensure
      clear_daemon
    end
  end

  it "raises the spawn failure raw when the daemon binary itself is unavailable" do
    begin
      error = assert_raises(Exception) do
        spec_send(command_config("echo never"), plugin_path: "/does/not/exist/krikri-plugin")
      end
      # Nothing was cached (the spawn never produced a process), so the
      # caller's fallback is safe to re-execute.
      cached_process.must_be_nil
      error.message.to_s.includes?("/does/not/exist/krikri-plugin").must_equal(true)
    ensure
      clear_daemon
    end
  end

  it "stops attempting the daemon after MAX_DAEMON_FAILURES consecutive failures, and a success resets the count" do
    3.times do
      dead = fake_daemon("exit 0")
      dead.wait
      seed_daemon(dead)
      assert_raises(Exception) { spec_send(command_config("echo never")) }
      # Each failed send evicted its (already dead) daemon; the NEXT
      # attempt spawns a fresh one, which fails the same way - the
      # consecutive-failure pattern a real run's hard-broken daemon shows.
      cached_process.must_be_nil
    end

    Krikri::LocalPluginDaemon.daemon_unavailable?(spec_host, nil).must_equal(true)

    skip "fat plugin binary not built (run ./build.sh first)" unless File.exists?(fat_binary)
    # Any success resets the breaker - the lazy-respawn story.
    spec_send(command_config("echo back"))["stdout"].as_s.must_equal("back")
    Krikri::LocalPluginDaemon.daemon_unavailable?(spec_host, nil).must_equal(false)
  ensure
    clear_daemon
  end
end
