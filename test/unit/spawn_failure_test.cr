require "../minitest_helper"
require "../../src/krikri/local_executor"
require "../../src/krikri/ssh_manager"

# Issue #704: a spawn failure (Process.new / pipe setup could not run the
# command at all) used to be reported as a normal-looking fake result
# ({exit_code: 1, ...} locally, exit 255 with "SSH execution failed" over
# SSH), indistinguishable from a command that really ran and exited nonzero -
# so plugins branching on the exit code (sysctl's "no live value" probe)
# took silently wrong branches and reported success.
#
# The spawn failure is forced through the KRIKRI_TEST_FORCE_SPAWN_FAILURE
# hook: plugins run as separate subprocesses, so an in-process class override
# in a test cannot reach their LocalExecutor - the env var does, through
# PluginSpecHelper's child `env:`. Direct LocalExecutor calls pass it via the
# `env:` argument instead of process ENV so those tests stay parallel-safe;
# the SSHManager hook (in ssh_manager.cr) only reads process ENV, so its
# describe mutates process ENV and therefore declares exclusive! - the
# mutation is visible to every process in the suite (including the plugin
# binaries other tests spawn), so ALL other tests must be quiesced, which
# plain serial! does not guarantee.
module SpawnFailureTest
  HOOK_ENV = {"KRIKRI_TEST_FORCE_SPAWN_FAILURE" => "1"}
  HOOK_VAR = "KRIKRI_TEST_FORCE_SPAWN_FAILURE"
end

describe "spawn failure vs real exit code (#704)" do
  it "exec without opt-in still returns the legacy fake result shape" do
    result = Krikri::LocalExecutor.exec("true", env: SpawnFailureTest::HOOK_ENV)
    result[:exit_code].must_equal(1)
    result[:stdout].must_equal("")
    result[:stderr].must_match(/Local execution failed/)
    result[:stderr].must_match(/simulated spawn failure/)
  end

  it "exec with raise_spawn_errors raises SpawnError instead of a fake result" do
    ex = assert_raises(Krikri::SpawnError) do
      Krikri::LocalExecutor.exec("true", env: SpawnFailureTest::HOOK_ENV, raise_spawn_errors: true)
    end
    ex.message.to_s.must_match(/Failed to spawn process/)
    ex.message.to_s.must_match(/simulated spawn failure/)
  end

  it "a real nonzero exit is still its own exit code with raise_spawn_errors" do
    result = Krikri::LocalExecutor.exec("sh -c 'exit 3'", raise_spawn_errors: true)
    result[:exit_code].must_equal(3)
  end

  it "a successful command still returns 0 with raise_spawn_errors" do
    result = Krikri::LocalExecutor.exec("sh -c 'exit 0'", raise_spawn_errors: true)
    result[:exit_code].must_equal(0)
  end

  it "a missing executable keeps the legacy fake result even with raise_spawn_errors" do
    # Carve-out: on the argv fast path a missing binary is Process.new's
    # File::NotFoundError, but through a shell it is the shell's own nonzero
    # "command not found" exit - probe-style callers ("is rpm installed?")
    # must keep reading it as a nonzero rc, so it is NOT a raised spawn
    # failure (full rationale at LocalExecutor.exec's rescue).
    result = Krikri::LocalExecutor.exec("krikri-definitely-not-a-binary-704", raise_spawn_errors: true)
    result[:exit_code].must_equal(1)
    result[:stderr].must_match(/Local execution failed/)
  end

  it "a non-executable file keeps the legacy fake result even with raise_spawn_errors" do
    # The carve-out covers the whole File::Error family, not just the
    # missing-binary case: a non-executable file is Process.new's
    # File::AccessDeniedError on the argv fast path, but through a shell
    # it is the shell's own nonzero "permission denied" exit - same
    # shell-equivalence reasoning as the missing-binary test above.
    path = PluginSpecHelper.tmp_path("nonexec-704")
    File.write(path, "not a program\n")
    File.chmod(path, 0o644)
    result = Krikri::LocalExecutor.exec(path, raise_spawn_errors: true)
    result[:exit_code].must_equal(1)
    result[:stdout].must_equal("")
    result[:stderr].must_match(/Local execution failed/)
  end
end

describe "SSHManager spawn failure vs real exit 255 (#704)" do
  exclusive! # mutates process-wide ENV, which every test in the suite can see

  it "exec with raise_spawn_errors raises SpawnError when ssh cannot be spawned" do
    ENV[SpawnFailureTest::HOOK_VAR] = "1"
    ex = assert_raises(Krikri::SpawnError) do
      Krikri::SSHManager.exec("127.0.0.1", "nobody", "true", raise_spawn_errors: true)
    end
    ex.message.to_s.must_match(/Failed to spawn process/)
  ensure
    ENV[SpawnFailureTest::HOOK_VAR] = nil
  end

  it "exec without opt-in keeps the legacy 255 SSH-execution-failed shape" do
    ENV[SpawnFailureTest::HOOK_VAR] = "1"
    result = Krikri::SSHManager.exec("127.0.0.1", "nobody", "true")
    result[:exit_code].must_equal(255)
    result[:stderr].must_match(/SSH execution failed/)
    result[:stderr].must_match(/simulated spawn failure/)
  ensure
    ENV[SpawnFailureTest::HOOK_VAR] = nil
  end

  it "exec_script with raise_spawn_errors raises SpawnError when ssh cannot be spawned" do
    ENV[SpawnFailureTest::HOOK_VAR] = "1"
    ex = assert_raises(Krikri::SpawnError) do
      Krikri::SSHManager.exec_script("127.0.0.1", "nobody", "true", raise_spawn_errors: true)
    end
    ex.message.to_s.must_match(/Failed to spawn process/)
  ensure
    ENV[SpawnFailureTest::HOOK_VAR] = nil
  end

  it "exec_script without opt-in keeps the legacy 255 script-failed shape" do
    ENV[SpawnFailureTest::HOOK_VAR] = "1"
    result = Krikri::SSHManager.exec_script("127.0.0.1", "nobody", "true")
    result[:exit_code].must_equal(255)
    result[:stderr].must_match(/SSH script execution failed/)
  ensure
    ENV[SpawnFailureTest::HOOK_VAR] = nil
  end
end

# End-to-end through the real plugin binary: sysctl's live-value probe
# (`sysctl -e -n <key>`) reads a nonzero rc as "no live value", which with
# sysctl_set: true used to turn a spawn failure into changed: true and a
# SUCCESS result - the exact #704 masquerade. With the opt-in the plugin must
# fail, never report success.
describe "sysctl plugin reports failure on spawn failure (#704)" do
  it "fails with Failed to spawn process when sysctl cannot be spawned" do
    conf = PluginSpecHelper.tmp_path("spawn-fail.conf")
    File.write(conf, "net.ipv4.ip_forward=1\n")

    result = PluginSpecHelper.run("sysctl", {
      "name"        => "net.ipv4.ip_forward",
      "value"       => "1",
      "sysctl_file" => conf,
      "reload"      => "false",
      "sysctl_set"  => "true",
    }, env: {"KRIKRI_TEST_FORCE_SPAWN_FAILURE" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_match(/Failed to spawn process/)
  end
end
