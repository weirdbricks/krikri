require "../minitest_helper"
require "file_utils"
require "socket"
require "../../src/krikri/plugin_manager"

# These specs drive the compiled `bin/krikri-playbook` binary against the
# example playbooks in testing/*.yml, in --check mode, using an inventory
# that defines no hosts. Fixtures targeting the "testservers" group therefore
# have their play skipped (no hosts match) rather than actually connecting
# anywhere; the "localhost" fixture runs for real, but every plugin it uses
# (shell/debug) refuses to act in check mode, so nothing on disk changes.
# This turns the manual fixtures into a regression net for free, without
# requiring SSH access or a target host.

private PROJECT_ROOT                 = File.expand_path("../..", __DIR__)
private BINARY                       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY                    = File.join(__DIR__, "..", "fixtures", "inventory.ini")
private EXPLICIT_LOCALHOST_INVENTORY = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")
private TWO_LOCAL_HOSTS_INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-two-local-hosts.ini")
private FIXTURES_DIR                 = File.join(PROJECT_ROOT, "testing")

# The classic suite assigned these to describe-body locals (visible to the
# nested closure its); minitest's describe bodies are class bodies, so they
# become methods.
private def testservers_inventory : String
  File.join(__DIR__, "..", "fixtures", "inventory-testservers-local.ini")
end

private def magicvars_inventory : String
  File.join(__DIR__, "..", "fixtures", "inventory-ansible-host.ini")
end

private def hostvars_inventory_file : String
  File.join(__DIR__, "..", "fixtures", "inventory-hostvars-local.ini")
end

private def explicit_localhost_plus_h1_inventory : String
  File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost-plus-h1.ini")
end

# minitest.cr has no before_suite hook; the classic suite built the
# binaries lazily here, the minitest suite expects ./build.sh to have run
# already, so this only fails fast when that precondition is missing.
raise "bin/krikri-playbook and bin/plugins/ missing - run ./build.sh first" unless File.exists?(BINARY) && Dir.exists?(File.join(PROJECT_ROOT, "bin", "plugins"))

# The classic suite wrote scratch playbooks under the shared spec/tmp;
# minitest runs tests concurrently, so they live in the per-test
# tmp_path subtree instead.
private def spec_tmp_path(name : String = "") : String
  PluginSpecHelper.tmp_path(name)
end

private def write_notify_playbook(name : String, body : String) : String
  path = spec_tmp_path(name)
  File.write(path, body)
  path
end

private def run_playbook(
  fixture : String,
  mode_args : Array(String) = ["--check"],
  chdir : String? = nil,
  inventory : String = INVENTORY,
  env : Hash(String, String)? = nil,
) : {Process::Status, String}
  output = IO::Memory.new
  playbook = fixture.starts_with?("/") ? fixture : File.join(FIXTURES_DIR, fixture)
  status = Process.run(
    BINARY,
    mode_args + ["-i", inventory, playbook],
    output: output,
    error: output,
    chdir: chdir,
    env: env
  )
  {status, output.to_s}
end

# The daemon-dependent smoke tests need real daemons the dev box may or
# may not have running; where they're absent the spec can't exercise
# anything, so it pendings instead of failing (matches the
# "requires a real ..." in the titles).
private def daemon_reachable?(host : String, port : Int32) : Bool
  sock = TCPSocket.new(host, port, connect_timeout: 1)
  sock.close
  true
rescue
  false
end

private def docker_daemon_ready? : Bool
  # The docker CLI honors DOCKER_HOST; with no env override, a reachable
  # /var/run/docker.sock is the usual local-daemon signal.
  return false if ENV["DOCKER_HOST"]?.nil? && !File.exists?("/var/run/docker.sock")
  status = Process.run("docker", ["info"], output: Process::Redirect::Close, error: Process::Redirect::Close)
  status.success?
rescue
  false
end

# testing/test-docker-quick.yml treats localhost/krikri-playbook-compat:latest
# as an ambient precondition (the compat harness's compat/Dockerfile builds it
# on dev boxes) - a pull of that ref fails on any daemon where it isn't
# already present, since there is no localhost registry. So a reachable
# daemon alone isn't enough to run the fixture; the image must be there.
private def docker_smoke_image_ready? : Bool
  return false unless docker_daemon_ready?
  status = Process.run("docker", ["image", "inspect", "localhost/krikri-playbook-compat:latest"],
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  status.success?
rescue
  false
end

describe "krikri-playbook CLI (--check mode)" do
  # minitest's describe/it macros cannot expand inside a runtime block,
  # and `it` names cannot interpolate, so the classic suite's Dir.glob
  # loop over testing/*.yml is unrolled into one static it per fixture
  # (same tests, same order).
  it "runs test-apt.yml to completion" do
    status, output = run_playbook("test-apt.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-async-quick.yml to completion" do
    # Own HOME, so its ~/.ansible_async jobs can't be swept by anything
    # else on the host (see the async/poll/async_status test below).
    home = PluginSpecHelper.tmp_path("home")
    Dir.mkdir_p(home)
    status, output = run_playbook("test-async-quick.yml", env: {"HOME" => home})

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-become-quick.yml to completion" do
    status, output = run_playbook("test-become-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-block-notify-quick.yml to completion" do
    status, output = run_playbook("test-block-notify-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-block-skip-prefix-role.yml to completion" do
    status, output = run_playbook("test-block-skip-prefix-role.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-block-skip-prefix.yml to completion" do
    status, output = run_playbook("test-block-skip-prefix.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-changed-when-quick.yml to completion" do
    status, output = run_playbook("test-changed-when-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-command-argv.yml to completion" do
    status, output = run_playbook("test-command-argv.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-command.yml to completion" do
    status, output = run_playbook("test-command.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-connection-local-quick.yml to completion" do
    status, output = run_playbook("test-connection-local-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-copy-quick.yml to completion" do
    status, output = run_playbook("test-copy-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-copy.yml to completion" do
    status, output = run_playbook("test-copy.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-cron-authorized-key-quick.yml to completion" do
    status, output = run_playbook("test-cron-authorized-key-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-debug-quick.yml to completion" do
    status, output = run_playbook("test-debug-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-delegate-loop-item-quick.yml to completion" do
    status, output = run_playbook("test-delegate-loop-item-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-delegate-run-once-quick.yml to completion" do
    status, output = run_playbook("test-delegate-run-once-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-docker-quick.yml to completion" do
    status, output = run_playbook("test-docker-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-dynamic-inventory-quick.yml to completion" do
    status, output = run_playbook("test-dynamic-inventory-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-error-handling-quick.yml to completion" do
    status, output = run_playbook("test-error-handling-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-error-handling-unrescued.yml to completion" do
    status, output = run_playbook("test-error-handling-unrescued.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-explicit-localhost-hostvars-quick.yml to completion" do
    status, output = run_playbook("test-explicit-localhost-hostvars-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-fact-precedence-quick.yml to completion" do
    status, output = run_playbook("test-fact-precedence-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-facts-simple.yml to completion" do
    status, output = run_playbook("test-facts-simple.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-facts.yml to completion" do
    status, output = run_playbook("test-facts.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-forks-quick.yml to completion" do
    status, output = run_playbook("test-forks-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-gather-facts-false-quick.yml to completion" do
    status, output = run_playbook("test-gather-facts-false-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-gather-facts-true-quick.yml to completion" do
    status, output = run_playbook("test-gather-facts-true-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-gathering-smart-quick.yml to completion" do
    status, output = run_playbook("test-gathering-smart-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-group-host-vars-quick.yml to completion" do
    status, output = run_playbook("test-group-host-vars-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-groups-quick.yml to completion" do
    status, output = run_playbook("test-groups-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-hostvars-cache-invalidation-quick.yml to completion" do
    status, output = run_playbook("test-hostvars-cache-invalidation-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-hostvars-quick.yml to completion" do
    status, output = run_playbook("test-hostvars-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-idempotent.yml to completion" do
    status, output = run_playbook("test-idempotent.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-implicit-localhost-hostvars-quick.yml to completion" do
    status, output = run_playbook("test-implicit-localhost-hostvars-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-include-role-okcount-quick.yml to completion" do
    status, output = run_playbook("test-include-role-okcount-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-include-role-quick.yml to completion" do
    status, output = run_playbook("test-include-role-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-include-tasks-quick.yml to completion" do
    status, output = run_playbook("test-include-tasks-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-include-vars-noskip-fail.yml to completion" do
    status, output = run_playbook("test-include-vars-noskip-fail.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-include-vars-quick.yml to completion" do
    status, output = run_playbook("test-include-vars-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-include-vars-register.yml to completion" do
    status, output = run_playbook("test-include-vars-register.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-include-vars-relative-path.yml to completion" do
    status, output = run_playbook("test-include-vars-relative-path.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-limit-hosts.yml to completion" do
    status, output = run_playbook("test-limit-hosts.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-lineinfile-quick.yml to completion" do
    status, output = run_playbook("test-lineinfile-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-loop-counting.yml to completion" do
    status, output = run_playbook("test-loop-counting.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-loop-quick.yml to completion" do
    status, output = run_playbook("test-loop-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-loop-unknown-filter.yml to completion" do
    status, output = run_playbook("test-loop-unknown-filter.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-magic-vars-quick.yml to completion" do
    status, output = run_playbook("test-magic-vars-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-meta-clear-facts-quick.yml to completion" do
    status, output = run_playbook("test-meta-clear-facts-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-meta-clear-host-errors-quick.yml to completion" do
    status, output = run_playbook("test-meta-clear-host-errors-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-meta-end-host-quick.yml to completion" do
    status, output = run_playbook("test-meta-end-host-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-meta-end-play-quick.yml to completion" do
    status, output = run_playbook("test-meta-end-play-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-meta-end-role-quick.yml to completion" do
    status, output = run_playbook("test-meta-end-role-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-meta-flush-handlers-quick.yml to completion" do
    status, output = run_playbook("test-meta-flush-handlers-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-meta-noop-quick.yml to completion" do
    status, output = run_playbook("test-meta-noop-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-multihost-block-quick.yml to completion" do
    status, output = run_playbook("test-multihost-block-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-multihost-include-tasks-quick.yml to completion" do
    status, output = run_playbook("test-multihost-include-tasks-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-multihost-looped-include-tasks-quick.yml to completion" do
    status, output = run_playbook("test-multihost-looped-include-tasks-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-mysql-quick.yml to completion" do
    status, output = run_playbook("test-mysql-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-nested-loop-in-include-quick.yml to completion" do
    status, output = run_playbook("test-nested-loop-in-include-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-nested-role-parent-chain-quick.yml to completion" do
    status, output = run_playbook("test-nested-role-parent-chain-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-package.yml to completion" do
    status, output = run_playbook("test-package.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-postgresql-quick.yml to completion" do
    status, output = run_playbook("test-postgresql-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-query-first-found-loop.yml to completion" do
    status, output = run_playbook("test-query-first-found-loop.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-remote.yml to completion" do
    status, output = run_playbook("test-remote.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-roles-quick.yml to completion" do
    status, output = run_playbook("test-roles-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-run-once-fail-quick.yml to completion" do
    status, output = run_playbook("test-run-once-fail-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-service.yml to completion" do
    status, output = run_playbook("test-service.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-set-fact-quick.yml to completion" do
    status, output = run_playbook("test-set-fact-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-strict-undefined-module-arg.yml to completion" do
    status, output = run_playbook("test-strict-undefined-module-arg.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-task-vars-lazy-quick.yml to completion" do
    status, output = run_playbook("test-task-vars-lazy-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-template-debug.yml to completion" do
    status, output = run_playbook("test-template-debug.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-template-idempotent.yml to completion" do
    status, output = run_playbook("test-template-idempotent.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-template-simple.yml to completion" do
    status, output = run_playbook("test-template-simple.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-template-src-baked-in-prefix.yml to completion" do
    status, output = run_playbook("test-template-src-baked-in-prefix.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-template-src-no-templates-dir.yml to completion" do
    status, output = run_playbook("test-template-src-no-templates-dir.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-template.yml to completion" do
    status, output = run_playbook("test-template.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-unarchive-role-files.yml to completion" do
    status, output = run_playbook("test-unarchive-role-files.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-vars-context-cache-quick.yml to completion" do
    status, output = run_playbook("test-vars-context-cache-quick.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-with-first-found-custom-loop-var.yml to completion" do
    status, output = run_playbook("test-with-first-found-custom-loop-var.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs test-with-first-found-custom-paths.yml to completion" do
    status, output = run_playbook("test-with-first-found-custom-paths.yml")

    status.success?.must_equal(true)
    output.must_include("PLAY RECAP")
    output.must_include("Playbook execution complete")
    output.wont_include("Error parsing playbook")
    output.wont_include("Error loading inventory")
  end

  it "runs the localhost fixture in check mode without making changes" do
    status, output = run_playbook("test-debug-quick.yml")

    status.success?.must_equal(true)
    output.must_include("Mode: CHECK (dry-run)")
    output.must_include("ok: [localhost]")
    # shell.cr's check-mode skip now sets skipped: true (matching real
    # Ansible's own recap - `skipped=1`, verified against ansible-core
    # 2.19.4's own `--check` output for this exact fixture) and populates
    # the full normal result shape (cmd/rc/stdout/stdout_lines/stderr/
    # stderr_lines/start/end/delta), so it displays as a genuine
    # "skipping:" line rather than a disguised "ok:" with the message
    # text inline - see VarSubstitutor::UndefinedVariableError's own
    # comment for why the result-shape fix mattered once module-arg
    # templating became strict (`test_result.stdout` must resolve to a
    # real empty string, not a missing key).
    output.must_include("skipping: [localhost]")
    output.must_include("NOTE: Running in check mode - no changes were made")
  end

  it "iterates loop:, with_items:, with_dict:, with_nested:, with_sequence: and with_indexed_items:" do
    status, output = run_playbook("test-loop-quick.yml")

    status.success?.must_equal(true)
    output.must_include("=> (item=a)")
    output.must_include("loop item: a")
    output.must_include("=> (item=b)")
    output.must_include("=> (item=c)")
    output.must_include("with_items item: x")
    output.must_include("with_items item: y")
    output.must_include("one=1")
    output.must_include("two=2")
    output.must_include(%(nested item: ['a', 'x']))
    output.must_include(%(nested item: ['b', 'y']))
    output.must_include("sequence item: 1")
    output.must_include("sequence item: 3")
    output.must_include(%(indexed item: ['0', 'x']))
    output.must_include(%(indexed item: ['1', 'y']))
    output.must_include("var loop item: red")
    output.must_include("var loop item: green")
    output.must_include("var loop item: blue")
    output.must_include("var dict: one=1")
    output.must_include("var dict: two=2")
    output.must_include("max_requests=500")
    output.must_include("idx=0 item=red")
    output.must_include("idx=1 item=green")
    output.must_include("idx=2 item=blue")
  end

  it "flattens each with_items: source through a filter chain, not just a bare list, one level" do
    # geerlingguy.php's own `with_items: ["{{ php_conf_paths | flatten
    # }}", "{{ php_extension_conf_paths | flatten }}"]` (RHEL-family
    # round 60100): each source is a single `{{ }}` span but carries a
    # filter (`| flatten`), so #deep_render_item's own "whole input is
    # one bare expression, preserve native type" fast path (which only
    # recognized a bare/dotted VARIABLE reference, not one with a
    # filter chain) fell through to the generic substitute path and
    # STRINGIFIED each already-list-valued source instead of keeping it
    # a real Array - with_items's own one-level flatten only ever
    # unwraps an actual Array, so it silently no-op'd, and each `item`
    # ended up being the whole stringified one-element list instead of
    # its single scalar path. Verified idempotent too: a `file:
    # state: directory` on an existing directory must report `ok`, not
    # `changed`, which only happens if `item` is the real scalar path.
    dirs = [spec_tmp_path("flatten-a"), spec_tmp_path("flatten-b")]
    dirs.each { |dir| FileUtils.rm_rf(dir) }
    tmp = write_notify_playbook("with_items_filter_chain.yml", <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          conf_paths: ["#{dirs[0]}"]
          extension_conf_paths: ["#{dirs[1]}"]
        tasks:
          - name: make dirs
            ansible.builtin.file:
              path: "{{ item }}"
              state: directory
            with_items:
              - "{{ conf_paths | flatten }}"
              - "{{ extension_conf_paths | flatten }}"
      YAML
    begin
      captured = IO::Memory.new
      status = Process.run(BINARY, ["-i", "localhost,", tmp], output: captured, error: captured)
      status.success?.must_equal(true)
      out1 = captured.to_s
      out1.must_include("=> (item=#{dirs[0]})")
      out1.must_include("=> (item=#{dirs[1]})")
      out1.must_include("changed=1")

      captured2 = IO::Memory.new
      status2 = Process.run(BINARY, ["-i", "localhost,", tmp], output: captured2, error: captured2)
      status2.success?.must_equal(true)
      captured2.to_s.must_include("changed=0")
    ensure
      dirs.each { |dir| FileUtils.rm_rf(dir) }
      File.delete(tmp) rescue nil
    end
  end

  # The fixture bakes a /tmp path into the playbook; the minitest suite
  # runs tests concurrently, so each run rewrites it with its own
  # tmp_path subtree instead of the shared fixed path.
  private def write_loop_counting_playbook : String
    body = File.read(File.join(FIXTURES_DIR, "test-loop-counting.yml"))
      .gsub("/tmp/krikri-playbook-loop-count", PluginSpecHelper.tmp_path("loop-count"))
    path = PluginSpecHelper.tmp_path("test-loop-counting.yml")
    File.write(path, body)
    path
  end

  it "counts a looped task once in the recap (not once per item), matching Ansible" do
    # Real ansible-playbook aggregates a looped task into a single recap
    # line: a 3-item create loop reports ok=1 changed=1, never ok=3.
    # This guards the loop-aggregation parity fix in finish_looped_task.
    status, output = run_playbook(write_loop_counting_playbook, [] of String)

    status.success?.must_equal(true)
    output.must_include(%(localhost            : ok=1  changed=1  unreachable=0  failed=0))
  end

  it "always prints all 7 PLAY RECAP counters, even when 0, matching real ansible-playbook" do
    # Real ansible-playbook's recap always prints ok=/changed=/
    # unreachable=/failed=/skipped=/rescued=/ignored= in that exact
    # order, never conditionally omitting a 0-valued counter - verified
    # directly against a real ansible-playbook run. This used to omit
    # skipped=/rescued=/ignored= whenever they were 0, and never printed
    # unreachable= at all - a purely cosmetic recap-line divergence from
    # real Ansible found repeatedly across benchmark rounds.
    status, output = run_playbook(write_loop_counting_playbook, [] of String)

    status.success?.must_equal(true)
    output.must_include(%(unreachable=0  failed=0  skipped=0  rescued=0  ignored=0))
  end

  it "runs a role: meta dependency first, applies defaults/vars/invocation-var precedence, resolves src: relative to the role's files/ dir, fires role handlers, then runs the play's own tasks" do
    status, output = run_playbook("test-roles-quick.yml")

    status.success?.must_equal(true)
    task_order = output.lines.select(&.starts_with?("TASK ["))
    base_index = task_order.index(&.includes?("base role task runs first"))
    default_index = task_order.index(&.includes?("show the default var"))
    base_index.wont_be_nil
    default_index.wont_be_nil
    expect((base_index.as(Int32)) < (default_index.as(Int32))).must_equal(true)

    output.must_include("greeting target: krikri-playbook") # role invocation var overrides defaults/main.yml
    output.must_include("greeting style: friendly")         # from vars/main.yml
    output.must_include("Would copy")
    output.must_include("testing/roles/greeter/files/greeting.txt")
    output.must_include("announce greeting") # role handler fired (copy task reported changed)
    output.must_include("SUCCESS: play task ran after role tasks")
  end

  it "set_fact sets vars visible to later tasks (string/bool/int, when: gating, and overwrite)" do
    status, output = run_playbook("test-set-fact-quick.yml")

    status.success?.must_equal(true)
    output.must_include("greeting is hello from set_fact")
    output.must_include("retry_count is 3")
    output.must_include("is_ready gated task ran")
    output.must_include("greeting is updated greeting")
  end

  it "runs the Gathering Facts task and exposes ansible_* facts when gather_facts: true" do
    status, output = run_playbook("test-gather-facts-true-quick.yml", [] of String)

    status.success?.must_equal(true)
    output.must_include("TASK [Gathering Facts]")
    output.wont_include("hostname is {{ ansible_hostname }}") # substitution actually happened
  end

  it "skips the Gathering Facts task entirely when gather_facts: false" do
    status, output = run_playbook("test-gather-facts-false-quick.yml", [] of String)

    status.success?.must_equal(true)
    output.wont_include("TASK [Gathering Facts]")
    output.must_include("no facts needed here")
  end

  it "runs include_tasks: once per loop item with item: in scope, and skips the whole include (not per nested task) when its own when: is false" do
    status, output = run_playbook("test-include-tasks-quick.yml")

    status.success?.must_equal(true)
    output.must_include("dynamic task ran, item=a")
    output.must_include("dynamic task ran, item=b")
    output.must_include("dynamic task ran, item=c")
    output.scan("skipping: [localhost]").size.must_equal(1) # one skip for the whole `when: false` include, not one per nested task
    output.must_include("include_tasks smoke test complete!")

    # Regression: the when:-false include_tasks: used to increment
    # recap "ok" unconditionally BEFORE checking its own when:, then
    # "skipped" again once the check failed - double-counted as both
    # ok=8 and skipped=1 instead of the correct ok=7 skipped=1 (3 loop
    # iterations x (include + nested task) = 6, plus the final debug = 7).
    output.must_include("ok=7")
    output.must_include("skipped=1")
  end

  it "batches a top-level include_tasks: across every host sharing the same resolved file, instead of running it one whole host at a time" do
    # Real bug found benchmarking a real 2-node geerlingguy.kubernetes
    # cluster bring-up (round 37, 0.9.383): every task reached through a
    # top-level include_tasks: used to run against host 1 to completion,
    # then host 2 to completion - fully serial, bypassing --forks
    # parallelism for everything inside (which is most of a typical
    # role: geerlingguy.containerd/geerlingguy.kubernetes both gate
    # their OS-family setup this way). Measured as a consistent ~1.8x
    # cold-run wall-time regression on a real 2-host cluster playbook.
    status, output = run_playbook(
      "test-multihost-include-tasks-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.must_equal(true)
    output.must_include("included task ran on web1")
    output.must_include("included task ran on web2")
    # One shared "included: <path> for web1, web2" line - not two
    # separate single-host include resolutions.
    output.must_include("for web1, web2")
    output.must_include("multi-host include_tasks smoke test complete!")
  end

  it "batches a top-level block: across hosts too, still honoring per-host when: skips correctly" do
    status, output = run_playbook(
      "test-multihost-block-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.must_equal(true)
    output.must_include("block task ran on web1")
    output.wont_include("block task ran on web2")
    output.must_include("skipping: [web2]")
    output.must_include("multi-host block smoke test complete!")
  end

  it "forks a LOOPED top-level include_tasks: across hosts too, still threading each iteration's loop_var correctly per host" do
    # Round 37 (0.9.383) fixed the non-looped include_tasks: case above
    # but deliberately left a looped one (loop:/with_items: on the
    # include statement itself - rare, e.g. robertdebock.users' "Loop
    # over users_groups") on the original single-host path, since it
    # doesn't share execute_include_tasks_multi's per-file host grouping.
    # This exercises that looped case now being forkable via
    # task_forkable? too - each host still runs its own full loop
    # independently (not batched per-item across hosts like the
    # non-looped case), just concurrently with other hosts instead of
    # one host's whole loop finishing before the next host starts.
    status, output = run_playbook(
      "test-multihost-looped-include-tasks-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.must_equal(true)
    output.must_include("included task ran on web1 for fruit apple")
    output.must_include("included task ran on web1 for fruit banana")
    output.must_include("included task ran on web2 for fruit apple")
    output.must_include("included task ran on web2 for fruit banana")
    output.must_include("multi-host looped include_tasks smoke test complete!")
  end

  it "keeps a nested loop's own item bound inside a looped include_tasks:, not the outer include's item" do
    # Real bug found benchmarking robertdebock.diskspace: execute_looped_
    # task's per-iteration re-application of task.vars (needed so a task-
    # level vars: block recomputes against each item) blindly re-applied
    # EVERY task.vars key, including "item"/loop_var - which
    # execute_include_tasks had already propagated from the OUTER
    # iteration into task.vars for a NON-looped included task's benefit.
    # For an included task that ALSO loops, this silently clobbered the
    # correct inner-loop item with the stale outer one on every single
    # inner iteration.
    status, output = run_playbook("test-nested-loop-in-include-quick.yml")

    status.success?.must_equal(true)
    output.must_include(%(mount={'name': 'first'} item=a))
    output.must_include(%(mount={'name': 'first'} item=b))
    output.must_include(%(mount={'name': 'second'} item=a))
    output.must_include(%(mount={'name': 'second'} item=b))
    output.must_include("nested loop in include smoke test complete!")
  end

  it "runs include_role: once per loop item, applies invocation vars, and fires the role's handler exactly once even though the role (and its handler) were dynamically loaded twice" do
    status, output = run_playbook("test-include-role-quick.yml")

    status.success?.must_equal(true)
    output.must_include("hello krikri-playbook, item=x")
    output.must_include("hello krikri-playbook, item=y")
    # Role-prefixed ("include_role_target : ...") now that HANDLER
    # banners carry the owning role's name, matching real Ansible.
    output.scan("HANDLER [include_role_target : dynamically included handler]").size.must_equal(1)
    output.must_include("include_role smoke test complete!")
  end

  it "counts a non-looped include_role: task itself as one `ok` in the PLAY RECAP, matching real Ansible" do
    # Real bug found benchmarking andrewrothstein.terraform (round 154
    # v3): execute_include_tasks's run_include_tasks_once already
    # credited a non-looped include_tasks: with its own `ok`, but the
    # equivalent fix was never mirrored onto include_role:'s
    # run_include_role_once - every include_role: call silently
    # undercounted the recap's ok= tally by 1, verified against real
    # ansible-playbook (both give ok=5 changed=1 for this fixture: the
    # include_role: itself, its 2 tasks, the SUCCESS task, and the
    # notified handler).
    status, output = run_playbook("test-include-role-okcount-quick.yml")

    status.success?.must_equal(true)
    output.must_include("ok=5  changed=1")
  end

  it "propagates ansible_parent_role_names through a role's own include_tasks: -> include_role: chain" do
    # Real bug found benchmarking prometheus.prometheus.node_exporter (a
    # real Ansible Collection): its own tasks/main.yml reaches a nested
    # include_role: (with tasks_from:) via an intermediate include_tasks:
    # call, not directly. ansible_parent_role_names previously only got
    # set on tasks loaded straight from RoleLoader - propagate_role_context
    # (which threads role context through include_tasks:) never carried
    # role_name/role_parent_names at all, so the nested include_role:
    # call had no enclosing-role context to extend, and the target role's
    # own "don't invoke me directly" guard assert failed regardless of
    # the real (indirect) invocation path.
    status, output = run_playbook("test-nested-role-parent-chain-quick.yml")

    status.success?.must_equal(true)
    output.must_include("nested role chain complete! parent=outer_role")
    output.must_include("nested role parent-chain smoke test complete!")
  end

  it "continues the play past a failed task when ignore_errors: yes, and does not fail the process" do
    status, output = run_playbook("test-error-handling-quick.yml", [] of String)

    status.success?.must_equal(true)
    output.must_include("ignore_errors let the play continue")
  end

  it "overrides changed/failed via changed_when:/failed_when:" do
    status, output = run_playbook("test-changed-when-quick.yml", [] of String)

    status.success?.must_equal(true)
    lines = output.lines

    status_after = ->(task_line : String) {
      task_index = lines.index(&.includes?(task_line))
      task_index.wont_be_nil
      status_line = lines[(task_index.as(Int32) + 1)..].find { |line| line.starts_with?("ok:") || line.starts_with?("changed:") || line.starts_with?("failed:") }
      status_line.wont_be_nil
      status_line.as(String)
    }

    expect(status_after.call("a command that would normally report changed, forced to ok").starts_with?("ok:")).must_equal(true)
    expect(status_after.call("a command whose changed status is derived from its own rc").starts_with?("ok:")).must_equal(true)
    expect(status_after.call("a command downgraded from failed to ok via failed_when").starts_with?("changed:")).must_equal(true)

    output.must_include("failed_when: false let the play continue")
    output.must_include("changed_when / failed_when smoke test complete!")
    output.wont_include("failed=1")
  end

  it "runs run_once: only on the first host but still exposes its register: to every host, and keeps delegate_to: vars attributed to the delegating host" do
    status, output = run_playbook(
      "test-delegate-run-once-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.must_equal(true)
    # run_once: only actually executes (and is displayed/counted) for the
    # first host in the play.
    output.must_include("changed: [web1]")
    output.wont_include("changed: [web2]")
    # but its registered result is still visible from both hosts.
    output.scan("once_result changed=True").size.must_equal(2)
    # delegate_to: redirects the connection, not the variables - each
    # host's own inventory_hostname still shows through.
    output.must_include("inventory_hostname=web1")
    output.must_include("inventory_hostname=web2")
    output.must_include("delegate_to / run_once smoke test complete!")
  end

  it "halts every host in the play when a run_once: task fails, while only the executing host's failure is counted" do
    status, output = run_playbook(
      "test-run-once-fail-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-three-local-hosts.ini")
    )

    # Real ansible-playbook 2.19.11 behavior: the failed run_once result
    # marks every host in the play failed (no host proceeds into later
    # tasks), but only the executing host's failures stat is incremented.
    status.success?.must_equal(false)
    # The next task's banner/output never appears for ANY host.
    output.wont_include("should never run")
    output.wont_include("TASK [never reached by any host]")
    # Only the executing host shows a failure line; the other two get
    # nothing of their own for this task. A non-loop failed task displays
    # as real ansible-core does: `fatal: [host]: FAILED! => {json}`.
    output.scan(/fatal: \[node/).size.must_equal(1)
    # Recap: exactly one failure, spread over the three hosts.
    output.must_include("failed=1")
    output.wont_include("failed=2")
    output.wont_include("failed=3")
  end

  it "re-resolves a templated delegate_to: per loop iteration instead of once before the loop binds item" do
    status, output = run_playbook(
      "test-delegate-loop-item-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.must_equal(true)
    # run_once: true picks web1 as the sole executor; its delegated loop
    # (delegate_to: "{{ item }}") sets loop_delegate_marker="web1" onto
    # BOTH web1 and web2 via delegate_facts - if delegate_to resolved
    # against an unbound "item" (the bug), the task would have crashed
    # trying to SSH to a host literally named "undefined" instead of
    # ever reaching here.
    output.must_include("host=web1 marker=web1")
    output.must_include("host=web2 marker=web1")
    output.wont_include("marker=undefined")
    output.must_include("delegate_to templated on loop item smoke test complete!")
  end

  it "keeps a play var winning over an ordinary fact-gathering module's same-name fact, while set_fact still overrides it" do
    # Found live testing itigoag.packages (round 301's json_query fix):
    # a play-level `vars: packages: {...}` was being silently clobbered
    # by `package_facts:`'s own `ansible_facts.packages` (registered
    # under the bare name "packages" too) - real ansible-playbook's
    # "host facts" precedence tier sits BELOW play vars, so the play
    # var must win; only set_fact's own much higher tier is allowed to
    # override it unconditionally.
    status, output = run_playbook("test-fact-precedence-quick.yml")

    status.success?.must_equal(true)
    output.must_include("packages is {'foo': 1}")
    output.must_include("gathered package count is")
    output.wont_include("gathered package count is 0")
    output.must_include("packages is now {'bar': 2}")
  end

  describe "include_vars: / with_first_found:" do
    it "loads a file chosen by with_first_found into a named dict, and merges without name:" do
      status, output = run_playbook(
        "test-include-vars-quick.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      # `name:` stages the whole file under one variable...
      output.must_include("named=from-os-family-file")
      # ...while the bare form merges its keys into the context.
      output.must_include("merged=from-os-family-file")
    end

    it "keeps set_fact: winning over include_vars:" do
      status, output = run_playbook(
        "test-include-vars-quick.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      # include_vars sits below set_fact in real Ansible's precedence
      # ladder, and @included_vars is applied before facts for that reason.
      output.must_include("precedence=from-set-fact")
    end

    it "skips rather than fails when no with_first_found candidate exists and skip: true" do
      status, output = run_playbook(
        "test-include-vars-quick.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      output.must_include("skipping:")
      output.wont_include("file not found")
    end

    it "resolves a with_first_found candidate that bakes vars/ into the filename against the role root" do
      # Real bug found benchmarking geerlingguy.mysql: a candidate like
      # "vars/Linux.yml" (the vars/ prefix baked into the filename itself,
      # rather than relying on a separate paths:) previously only ever
      # got joined against the role's vars/ dir directly - producing a
      # nonexistent doubled "vars/vars/Linux.yml" - so this always
      # silently resolved to zero candidates via skip: true.
      status, output = run_playbook(
        "test-include-vars-quick.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      output.must_include("prefixed=from-os-family-file")
    end

    it "fails (not skips) when no with_first_found candidate exists and skip: true is NOT given" do
      # Real bug found benchmarking robertdebock.release on Rocky 9.6:
      # real Ansible's first_found lookup plugin defaults `skip:` to
      # false - with no candidate found it raises and the include_vars:
      # task FAILS, it does not silently skip. Only explicit `skip: true`
      # (already covered by the specs above) tolerates a miss.
      status, output = run_playbook(
        "test-include-vars-noskip-fail.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(false)
      output.must_include("The lookup plugin 'first_found' failed")
    end

    it "resolves query('first_found', ...) as a real include_vars: loop source, with a custom loop_var and a tasks/-relative paths: entry" do
      # Real bug found benchmarking buluma.confluence (round 165) -
      # three independent gaps in one common modern idiom:
      #  1. query(...) (real Ansible's lookup(..., wantlist=True)
      #     shorthand) was entirely unrecognized as a function call.
      #  2. parse_include_vars_task (a dedicated parser, not the
      #     general task-parsing path) never called #find_loop_template
      #     at all, so a TEMPLATED loop: (as opposed to a literal list
      #     or with_first_found:) left task.loop_template nil.
      #  3. The same dedicated parser never read loop_control: either,
      #     so a custom loop_var (`_loop_var` here) never got bound -
      #     Also: a `paths: ['../vars']` entry resolves against the
      #     including task file's own directory (tasks/), not just
      #     role_path itself.
      status, output = run_playbook(
        "test-query-first-found-loop.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      output.must_include("confluence_marker=found-via-query")
    end

    it "resolves with_first_found: as an include_vars: loop source, with a custom loop_var" do
      # Real bug found benchmarking 13 different arillso.* roles
      # (docker, motd, ntp, openvpn, sshd, sudoers, ...), all sharing
      # this exact idiom: with_first_found: (the dedicated keyword, not
      # lookup()/query()) combined with loop_control: { loop_var:
      # loop_vars }. Unlike the loop:/query() path above (fixed for
      # buluma.confluence, round165), the DEDICATED with_first_found:
      # branch in TaskExecutor#execute_include_vars is a separate code
      # path that only ever bound the found candidate to the literal
      # name "item", ignoring loop_control entirely - `include_vars:
      # "{{ loop_vars }}"` always resolved to the literal text
      # "undefined" regardless of which candidate file actually
      # matched, failing "include_vars: file not found: undefined" on
      # every single one of these roles.
      status, output = run_playbook(
        "test-with-first-found-custom-loop-var.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      output.must_include("arillso_marker=found-via-with-first-found")
    end

    it "honors with_first_found:'s own custom paths: sub-key, not just the hardcoded search roots" do
      # Real bug found benchmarking arillso.authorized_key's own
      # "include distribution tasks": with_first_found:'s dict form
      # (`- files: [...] paths: [...]`) silently discarded its own
      # paths: sub-key at parse time (PlaybookParser#parse_first_found
      # only ever extracted files:) - resolution always fell back to the
      # hardcoded files/templates/vars/role-root search roots regardless
      # of what paths: actually named, so a custom directory ("distribution"
      # here) was never searched and the loop always silently skipped,
      # matching neither real Ansible's success nor a real failure.
      status, output = run_playbook(
        "test-with-first-found-custom-paths.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      output.must_include("arillso_authorized_key_marker=found-via-custom-paths")
    end

    it "resolves a relative include_vars: path against the role's own tasks/ dir, not just role_vars_dir/Dir.current" do
      # Real bug found benchmarking jnv.debian-backports's own "add
      # distribution-specific variables" task: `include_vars:
      # "../defaults/{{ ansible_distribution }}.yml"` - a plain relative
      # path (not with_first_found:), meant to resolve against the
      # CURRENT task file's own directory. A role with no vars/ dir at
      # all (only defaults/, like this one) had no matching search root
      # here whatsoever - role_vars_dir stays nil, include_file_dir
      # stays nil (only set for an actually include_tasks:'d file, not
      # a role's own top-level tasks/main.yml), leaving only the
      # process's own irrelevant Dir.current - so the file was never
      # found even though it genuinely exists.
      status, output = run_playbook(
        "test-include-vars-relative-path.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      output.must_include("backports_marker=found-via-relative-path")
    end
  end

  describe "strict-undefined module-arg templating" do
    it "fails (not silently continues) when a bare module-arg reference is genuinely undefined" do
      # Real bug found benchmarking robertdebock.bios_update on Rocky 9.6
      # (round 161): real Ansible's module-arg templating is
      # strict-undefined by default - a debug: msg: inside a rescue:
      # block referencing a variable that's genuinely never set anywhere
      # fails the task ("Finalization of task args ... failed") rather
      # than silently rendering the literal text "undefined" and
      # continuing. Verified live against ansible-core 2.19.4: both
      # engines now fail at the same task with the same message.
      status, output = run_playbook(
        "test-strict-undefined-module-arg.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(false)
      output.must_include("'some_var_never_set' is undefined")
    end
  end

  describe "template:/copy: src: with the subdir prefix already baked in" do
    it "resolves src: against the role ROOT, not role_templates_dir again, when src: already bakes in the subdir prefix" do
      # Real bug found benchmarking buluma.confluence (round 165):
      # `src: "./templates/nested/dir/file.j2"` (the "templates/" subdir
      # prefix already baked into src: itself - real Ansible resolves
      # this against the role ROOT) previously always joined against
      # role_templates_dir directly, doubling the subdir
      # (".../templates/templates/nested/...", never existing) - "Template
      # file not found on controller" for every role using this idiom.
      status, output = run_playbook(
        "test-template-src-baked-in-prefix.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      output.wont_include("Template file not found")
      File.read("/tmp/template_src_prefix_test_output.txt").must_include("value=baked-in-prefix-works")
    ensure
      File.delete("/tmp/template_src_prefix_test_output.txt") if File.exists?("/tmp/template_src_prefix_test_output.txt")
    end
  end

  describe "template:/copy: src: in a role with no top-level templates dir" do
    it "resolves template: src: via the ROLE ROOT when role_templates_dir is nil" do
      # Real bug found benchmarking alivx.ansible_cis_nginx_hardening
      # (round 90192): the role has no templates/ dir at all - its
      # templates live under files/templates/ and its tasks pass
      # src: "files/templates/nodejs.conf". resolve_role_relative_src
      # bailed out on the nil role_templates_dir guard (role_loader only
      # sets role_templates_dir when that dir exists), so src: was never
      # resolved and the task failed with "Template file not found on
      # controller" where real ansible-playbook changed the file (its
      # search list goes <role>/templates/<src> then <role>/<src>).
      status, output = run_playbook(
        "test-template-src-no-templates-dir.yml", [] of String, inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      output.wont_include("Template file not found")
      File.read("/tmp/template_src_no_templates_dir_output.txt").must_include("value=no-templates-dir-works")
    ensure
      File.delete("/tmp/template_src_no_templates_dir_output.txt") if File.exists?("/tmp/template_src_no_templates_dir_output.txt")
    end
  end

  describe "magic variables" do
    it "are visible to bare when:/assert:/changed_when:/failed_when: conditions" do
      status, output = run_playbook(
        "test-magic-vars-quick.yml", [] of String, inventory: magicvars_inventory
      )

      status.success?.must_equal(true)
      # Each of these used to fail: a bare condition was evaluated
      # against vars_context, which never had the magic variables added -
      # only the {{ }} substitution path did. `when:` therefore skipped
      # silently, which is the worst shape for this bug.
      output.must_include("BARE-WHEN-RAN")
      output.must_include("CHANGED-WHEN=False")
      output.must_include("FAILED-WHEN-SURVIVED")
      output.wont_include("failed=1")
    end

    it "does not overwrite an inventory ansible_host with the inventory name" do
      status, output = run_playbook(
        "test-magic-vars-quick.yml", [] of String, inventory: magicvars_inventory
      )

      status.success?.must_equal(true)
      # ansible_host is the connection address, not the inventory name.
      # Overwriting it also mislead PluginManager#get_connection_host.
      # ansible-core 2.19.4 reports the inventory's value here.
      output.must_include("inv=web1 ahost=127.0.0.1")
    end

    it "prefers the gathered ansible_hostname fact over the inventory name" do
      status, output = run_playbook(
        "test-magic-vars-quick.yml", [] of String, inventory: magicvars_inventory
      )

      status.success?.must_equal(true)
      # ansible_hostname is a fact - the target's own hostname, which is
      # usually not the inventory name. Only used as a fallback when no
      # facts were gathered.
      real_hostname = System.hostname
      output.wont_include("ahostname=web1")
      # sanity: the fixture's inventory name and the real hostname differ,
      # otherwise this assertion proves nothing.
      real_hostname.wont_equal("web1")
    end
  end

  describe "--gathering" do
    it "defaults to implicit: every play re-gathers facts" do
      # ANSIBLE_GATHERING (a real Ansible config var this engine also
      # reads, see krikri-playbook.cr) is explicitly cleared here - this
      # assertion is specifically about the DEFAULT when nothing
      # overrides it, which would otherwise leak in from a developer's
      # own shell environment and falsely fail this spec.
      output = IO::Memory.new
      status = Process.run(
        BINARY,
        ["-i", testservers_inventory, File.join(FIXTURES_DIR, "test-gathering-smart-quick.yml")],
        output: output,
        error: output,
        env: {"ANSIBLE_GATHERING" => nil}
      )

      status.success?.must_equal(true)
      output.to_s.scan("TASK [Gathering Facts]").size.must_equal(3)
    end

    it "smart: gathers each host at most once per run" do
      status, output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "smart"], inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      output.scan("TASK [Gathering Facts]").size.must_equal(1)
    end

    it "smart: later plays still see the facts gathered by the first" do
      status, output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "smart"], inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      # The whole point: skipping the round trip must not mean skipping
      # the facts. All three plays resolve ansible_kernel, none falls
      # back to the default('MISSING').
      output.wont_include("MISSING")
      output.scan(/play\d kernel=/).size.must_equal(3)
    end

    it "smart and implicit produce the same task results, differing only in gathering" do
      _, implicit_output = run_playbook(
        "test-gathering-smart-quick.yml", [] of String, inventory: testservers_inventory
      )
      _, smart_output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "smart"], inventory: testservers_inventory
      )

      %w[play1 play2 play3].each do |play|
        implicit_line = implicit_output.lines.find(&.includes?("#{play} kernel="))
        smart_line = smart_output.lines.find(&.includes?("#{play} kernel="))
        smart_line.must_equal(implicit_line)
      end
    end

    it "explicit: gathers only for plays that actually wrote gather_facts: true" do
      status, output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "explicit"], inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      # Every play in that fixture writes `gather_facts: true`, so
      # explicit gathers for all three - the mode differs from implicit
      # only for plays that leave gather_facts unset.
      output.scan("TASK [Gathering Facts]").size.must_equal(3)
    end

    it "explicit: does not gather for a play that leaves gather_facts unset" do
      status, output = run_playbook(
        "test-meta-clear-facts-quick.yml", ["--gathering", "explicit"], inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      # Plays 1 and 3 leave gather_facts unset; play 2 sets it to false.
      output.wont_include("TASK [Gathering Facts]")
    end

    it "meta: clear_facts forces a re-gather in the next play under smart" do
      status, output = run_playbook(
        "test-meta-clear-facts-quick.yml", ["--gathering", "smart"], inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      # Without the clear_facts this would be 1; the clear in play 2 makes
      # play 3 gather again. Matches ansible-core 2.19.4 exactly.
      output.scan("TASK [Gathering Facts]").size.must_equal(2)
      output.wont_include("MISSING")
    end

    it "meta: produces no per-host output line and no recap credit" do
      status, output = run_playbook(
        "test-meta-clear-facts-quick.yml", ["--gathering", "smart"], inventory: testservers_inventory
      )

      status.success?.must_equal(true)
      # ansible-core prints the TASK banner for a meta task but no `ok:`
      # beneath it, and excludes it from the recap total - the 2
      # implicit Gathering Facts tasks (plays 1 and 3 under smart, see
      # the re-gather case above) each count as ok=1 like any
      # successful task, so 2 gathers + 2 debug tasks is 4, not 2.
      output.must_include("TASK [clear the gathered facts]")
      output.must_match(/ok=4\b/)
    end

    it "meta: flush_handlers runs pending handlers immediately, not just at end-of-play" do
      # Real bug found benchmarking robertdebock's own roles (round 18):
      # `ansible.builtin.meta: flush_handlers` was rejected at parse time
      # entirely (a documented scope cut) - several real roles
      # (mysql, selinux, zabbix_repository, zabbix_server,
      # core_dependencies) use it deliberately mid-role so a later task
      # can rely on a handler's side effect (e.g. an apt cache refresh)
      # having already happened - skipping it silently deferred every
      # notified handler to the very end of the play instead, which for
      # zabbix_server caused a genuine functional divergence from real
      # ansible-playbook: a package install task failed "Unable to
      # locate package" because the repo-add handler's own cache refresh
      # hadn't run yet.
      status, output = run_playbook("test-meta-flush-handlers-quick.yml", [] of String)

      status.success?.must_equal(true)
      task_order = output.lines.select { |line| line.starts_with?("TASK [") || line.starts_with?("HANDLER [") }
      handler_index = task_order.index(&.includes?("HANDLER [my flush handler]"))
      after_index = task_order.index(&.includes?("TASK [after the flush]"))
      handler_index.wont_be_nil
      after_index.wont_be_nil
      expect((handler_index.as(Int32)) < (after_index.as(Int32))).must_equal(true)

      # The handler fired exactly once - the mid-play flush picked it up,
      # and the implicit end-of-play flush must not re-run it a second
      # time (real ansible-playbook's own flush_handlers semantics: only
      # handlers notified SINCE the last flush are pending).
      output.scan("HANDLER [my flush handler]").size.must_equal(1)
    end

    it "meta: end_host stops only the current host, not others" do
      # Real Ansible's own doc: "per-host variation of end_play... causes
      # the play to end for the current host without failing it." Was
      # rejected at parse time entirely before this - see git log.
      # Verified live against real ansible-playbook for both assertions
      # below (a 2nd host whose own when: skips this exact task keeps
      # running afterward; the ended host's own pending notified handler
      # is suppressed, matching a real failure's handler-skip behavior
      # exactly even though this is NOT a failure).
      status, output = run_playbook(
        "test-meta-end-host-quick.yml", [] of String, inventory: TWO_LOCAL_HOSTS_INVENTORY
      )

      status.success?.must_equal(true)
      output.must_include("ran for hosttwo")
      output.wont_include("ran for hostone")
      output.wont_include("HANDLER [my end_host handler]")
    end

    it "meta: end_play stops every currently-active host, not just the one that triggers it" do
      # Real Ansible's own doc: "causes the play to end without failing
      # the host(s). Note that this affects all hosts." Verified live
      # against real ansible-playbook: genuinely global - hosttwo's own
      # when: skips this exact task entirely (never itself executes it)
      # but still gets blocked from the task after it, the moment
      # hostone's when: makes IT execute end_play.
      status, output = run_playbook(
        "test-meta-end-play-quick.yml", [] of String, inventory: TWO_LOCAL_HOSTS_INVENTORY
      )

      status.success?.must_equal(true)
      output.wont_include("should never print")
    end

    it "meta: clear_host_errors excludes a failed host from the rest of this play but not the next one" do
      # Real Ansible's own doc: "clears the failed state... available
      # for targeting in subsequent plays, but not continue execution in
      # the current play." Verified live against real ansible-playbook,
      # including the non-obvious part: clearing is global (acts on
      # every failed host in the play), not scoped to whichever host(s)
      # happen to still be active enough to individually execute this
      # meta task - the failed host itself is ALREADY excluded from this
      # task too, so scoping to the executing host alone would make the
      # feature unusable.
      status, output = run_playbook(
        "test-meta-clear-host-errors-quick.yml", [] of String, inventory: TWO_LOCAL_HOSTS_INVENTORY
      )

      status.success?.must_equal(true)
      # Same play: only hosttwo (never failed) reaches the task after
      # clear_host_errors - hostone stays excluded from the REST of this
      # play despite its error being cleared.
      output.must_include("same play ran for hosttwo")
      output.wont_include("same play ran for hostone")
      # Next play: both hosts are back, including hostone.
      output.must_include("next play ran for hostone")
      output.must_include("next play ran for hosttwo")
    end

    it "meta: noop does nothing and execution continues normally" do
      status, output = run_playbook("test-meta-noop-quick.yml", [] of String)

      status.success?.must_equal(true)
      output.must_include("reached after noop")
    end

    it "meta: end_role skips the calling role's remaining tasks but not the play's" do
      # ansible-core 2.18+ (verified live against 2.19.4: identical task
      # flow and recap - the ended role's remaining tasks are consumed
      # silently, with no banner and no skipped= counter bump, while the
      # play's own tasks after the role keep running).
      status, output = run_playbook("test-meta-end-role-quick.yml", [] of String)

      status.success?.must_equal(true)
      output.must_include("role task one ran")
      # The post-end_role role task: silently consumed - no banner, no
      # result, no recap counter.
      output.wont_include("role task three should be skipped")
      output.wont_include("role task three")
      # The play's own task after the role still runs.
      output.must_include("play task after role")
      output.must_include("ok=2")
    end

    it "meta: end_role outside a role aborts the run with real Ansible's parse error" do
      # Real Ansible rejects end_role at parse time wherever the role
      # context is absent (helpers.py's load_list_of_tasks), rc=4 -
      # verified live against ansible-core 2.19.4, including that a
      # when: false guard does NOT save it.
      tmp = File.tempname("meta-end-role-outside", ".yml")
      File.write(tmp, <<-YAML)
        - name: end_role outside a role
          hosts: localhost
          gather_facts: false
          tasks:
            - name: end the role
              ansible.builtin.meta: end_role
        YAML
      begin
        captured = IO::Memory.new
        status = Process.run(BINARY, ["-i", "localhost,", tmp], output: captured, error: captured)
        status.exit_code.must_equal(4)
        captured.to_s.must_include("Cannot execute 'end_role' from outside of a role")
      ensure
        File.delete(tmp) rescue nil
      end
    end

    it "meta: reset_connection lets execution continue and counts in no recap bucket" do
      # Real Ansible's result is a META: vv line only (msg "reset
      # connection", changed: False) - no recap bucket, execution
      # continues. Connection dropping itself is exercised live (it needs
      # real daemons); the task-flow contract is what a spec can pin.
      tmp = File.tempname("meta-reset-connection", ".yml")
      File.write(tmp, <<-YAML)
        - name: reset connection smoke test
          hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: reset the connection
              ansible.builtin.meta: reset_connection

            - name: after the reset
              ansible.builtin.debug:
                msg: "reached after reset_connection"
        YAML
      begin
        captured = IO::Memory.new
        status = Process.run(BINARY, ["-i", "localhost,", tmp], output: captured, error: captured)
        status.success?.must_equal(true)
        captured.to_s.must_include("reached after reset_connection")
        captured.to_s.must_include("ok=1")
      ensure
        File.delete(tmp) rescue nil
      end
    end

    it "reports an unsupported meta action instead of treating it as a no-op" do
      # A meta action this engine does not model is rejected at parse time
      # with a named error, rather than being accepted and silently doing
      # nothing - a `meta: frobnicate` that quietly did nothing
      # would change what the playbook means. (end_play/end_host/
      # clear_host_errors/noop/refresh_inventory/end_batch/end_role/
      # reset_connection are all real, supported actions now - see
      # PlaybookParser::SUPPORTED_META_ACTIONS and
      # TaskExecutor#execute_meta, each verified against real
      # ansible-playbook.)
      #
      # It surfaces as a warning and the task is dropped, which is how the
      # parser handles *every* parse error (see PlaybookParser.parse_tasks'
      # rescue) - not as a non-zero exit. An earlier version of this spec
      # asserted a failing exit code and passed for the wrong reason: the
      # resulting task-less play then hit a crash in show_recap, which is
      # what actually produced the non-zero status. That crash is fixed,
      # so this now asserts the behavior that is really there.
      tmp = File.tempname("meta-unsupported", ".yml")
      File.write(tmp, <<-YAML)
        - name: unsupported meta
          hosts: testservers
          gather_facts: false
          tasks:
            - name: frobnicate
              ansible.builtin.meta: frobnicate
        YAML
      begin
        captured = IO::Memory.new
        Process.run(BINARY, ["-i", testservers_inventory, tmp], output: captured, error: captured)
        captured.to_s.must_include("meta: frobnicate is not supported")
        # and the task genuinely did not run
        captured.to_s.wont_include("frobnicate the florb")
      ensure
        File.delete(tmp) rescue nil
      end
    end

    it "meta: refresh_inventory re-reads a dynamic inventory script without adding hosts to the current play" do
      # Real Ansible's own doc, verified live: "neither refresh_inventory
      # nor add_host add hosts to the hosts the current play iterates
      # over" - only a LATER play's own hosts: pattern match sees newly-
      # appeared hosts. The dynamic inventory script here reports 1 host
      # normally, 2 once a marker file exists - play 1 creates that
      # marker then refreshes, but must still only see the original
      # host; play 2 must see both.
      script = File.tempname("dynamic-inventory-refresh", ".sh")
      marker = File.tempname("dynamic-inventory-refresh-marker")
      File.delete(marker) rescue nil
      File.write(script, <<-SH)
        #!/bin/sh
        if [ -f #{marker} ]; then
          echo '{"all":{"hosts":["hostone","hosttwo"]},"_meta":{"hostvars":{"hostone":{"ansible_connection":"local"},"hosttwo":{"ansible_connection":"local"}}}}'
        else
          echo '{"all":{"hosts":["hostone"]},"_meta":{"hostvars":{"hostone":{"ansible_connection":"local"}}}}'
        fi
        SH
      File.chmod(script, 0o755)

      tmp = File.tempname("meta-refresh-inventory", ".yml")
      File.write(tmp, <<-YAML)
        - hosts: all
          gather_facts: false
          tasks:
            - name: create marker
              ansible.builtin.file:
                path: #{marker}
                state: touch
              delegate_to: localhost
            - name: refresh
              ansible.builtin.meta: refresh_inventory
            - name: play1 saw it
              ansible.builtin.debug:
                msg: "play1 saw {{ inventory_hostname }}"
        - hosts: all
          gather_facts: false
          tasks:
            - name: play2 saw it
              ansible.builtin.debug:
                msg: "play2 saw {{ inventory_hostname }}"
        YAML
      begin
        captured = IO::Memory.new
        status = Process.run(BINARY, ["-i", script, tmp], output: captured, error: captured)
        output = captured.to_s

        status.success?.must_equal(true)
        output.must_include("play1 saw hostone")
        output.wont_include("play1 saw hosttwo")
        output.must_include("play2 saw hostone")
        output.must_include("play2 saw hosttwo")
      ensure
        File.delete(tmp) rescue nil
        File.delete(script) rescue nil
        File.delete(marker) rescue nil
      end
    end

    it "rejects an unknown gathering mode" do
      status, output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "bogus"], inventory: testservers_inventory
      )

      status.success?.must_equal(false)
      output.must_include("--gathering must be 'implicit', 'explicit' or 'smart'")
    end
  end

  it "--forks 1 (one-host-at-a-time) produces the same content as the --forks 5 default's parallel fan-out" do
    default_status, default_output = run_playbook(
      "test-forks-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-multi-local.ini")
    )
    forks1_status, forks1_output = run_playbook(
      "test-forks-quick.yml",
      ["--forks", "1"],
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-multi-local.ini")
    )

    default_status.success?.must_equal(true)
    forks1_status.success?.must_equal(true)

    # Compared as a multiset of lines, not byte-for-byte: since 0.9.579
    # the parallel path prints each host's block as that host FINISHES
    # (real ansible-playbook's completion order), so the two runs can
    # legitimately order two adjacent host lines differently. What must
    # not change with --forks is WHAT happened - every line, once.
    forks1_output.lines.sort!.must_equal(default_output.lines.sort!)
  end

  it "--forks N runs every host per task, still runs run_once: only on the first host, and keeps each host's output un-interleaved" do
    status, output = run_playbook(
      "test-forks-quick.yml",
      ["--forks", "5"],
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.must_equal(true)
    # Every host actually ran the plain (non-run_once) task.
    output.must_include("changed: [web1]")
    output.must_include("changed: [web2]")
    # run_once: still only executes on the first host under --forks -
    # task_forkable? excludes it from the parallel fan-out entirely.
    output.scan("changed: [web1]").size.must_equal(2) # the plain task + run_once
    output.scan("changed: [web2]").size.must_equal(1) # the plain task only
    # ...but its registered result is still visible from both hosts.
    output.scan("once_result changed=True").size.must_equal(2)
    output.scan("cmd_result changed=True").size.must_equal(2)
    # Each host's own lines stay together, never interleaved mid-task by
    # the concurrent fan-out. The ORDER of the two is completion order
    # since 0.9.579 (matching real ansible-playbook, which reports the
    # host that finished first), so either arrangement is correct - what
    # must hold is that the two lines are adjacent, not split apart.
    adjacent = output.includes?("changed: [web1]\nchanged: [web2]") ||
               output.includes?("changed: [web2]\nchanged: [web1]")
    adjacent.must_equal(true)
    output.must_include("forks smoke test complete!")
  end

  it "loads group_vars/all.yml, group_vars/<group>.yml, and host_vars/<host>.yml from beside the inventory file" do
    status, output = run_playbook(
      "test-group-host-vars-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "group_host_vars", "inventory.ini")
    )

    status.success?.must_equal(true)
    output.must_include("datacenter=dc1 role=webserver app_version=1.2.3")
    output.must_include("group_vars / host_vars smoke test complete!")
  end

  it "runs async: tasks in the background, blocks for poll: > 0, and lets async_status: poll a poll: 0 job to completion" do
    # The playbook's job files go under $HOME/.ansible_async
    # (AsyncJobs::DIR is a require-time constant of the child). The real
    # ~/.ansible_async is host-wide - the async_jobs unit specs'
    # cleanup_all sweep, or any other process running this suite, wipes it
    # - so the child gets its own per-test HOME and nothing else can touch
    # its jobs.
    home = PluginSpecHelper.tmp_path("home")
    Dir.mkdir_p(home)
    status, output = run_playbook(
      "test-async-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-testservers-local.ini"),
      env: {"HOME" => home}
    )

    status.success?.must_equal(true)
    # poll: > 0 blocks and returns the real (finished) module result.
    output.must_include("polled_result finished=1 changed=True")
    # poll: 0 returns immediately with a job id, not the real result yet.
    output.must_match(/Job started: \S+/)
    # async_status: eventually sees the fire-and-forget job finish.
    output.must_include("job_result finished=1")
    output.must_include("async / poll / async_status smoke test complete!")
  end

  it "detects an executable inventory file as a dynamic inventory script and uses its --list JSON output" do
    status, output = run_playbook(
      "test-dynamic-inventory-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "dynamic_inventory", "inventory.sh")
    )

    status.success?.must_equal(true)
    output.must_include("ok: [dynhost1]")
    output.must_include("connection=local")
    output.must_include("dynamic inventory smoke test complete!")
  end

  # These three smoke tests need real daemons the dev box may or may not
  # have running; where they're absent the spec can't exercise anything,
  # so it pendings instead of failing (matches the "requires a real ..."
  # in the titles).
  it "manages a Docker image/network/container end to end with correct idempotency (requires a real Docker/Podman daemon)" do
    # Two preconditions: a reachable daemon (docker_daemon_ready?) AND the
    # fixture's ambient local image (docker_smoke_image_ready?) - see its
    # comment. Pend rather than fail when either is absent, same convention
    # as the mysql specs' server probe below.
    skip "no Docker/Podman daemon reachable" unless docker_daemon_ready?
    skip "Docker/Podman daemon reachable but localhost/krikri-playbook-compat:latest is absent (compat/Dockerfile builds it; CI provides a stand-in)" unless docker_smoke_image_ready?
    status, output = run_playbook(
      "test-docker-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-testservers-local.ini")
    )

    status.success?.must_equal(true)
    output.must_include("image_first=False image_idempotent=False")
    output.must_include("network_first=True network_idempotent=False")
    output.must_include("container_first=True container_idempotent=False")
    output.must_include("container_stopped=True container_removed=True")
    output.must_include("network_removed=True")
    output.must_include("docker plugins smoke test complete!")
  end

  it "manages a MySQL/MariaDB database and user (with privilege diffing) end to end (requires a real server at 127.0.0.1:13306)" do
    skip "no MySQL/MariaDB server at 127.0.0.1:13306" unless daemon_reachable?("127.0.0.1", 13306)
    status, output = run_playbook(
      "test-mysql-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-testservers-local.ini")
    )

    status.success?.must_equal(true)
    output.must_include("db_first=True db_idempotent=False")
    output.must_include("db_import=True db_dump=True db_import_gz=True")
    output.must_include("restored_count=2")
    output.must_include("db_dump_zst=True")
    output.must_include("db_import_zst=True")
    output.must_include("restored_count_zst=2")
    output.must_include("db_dump_knobs=True")
    output.must_include("db_import_knobs=True")
    output.must_include("knobs_tables=t,")
    output.must_include("user_first=True user_idempotent=False")
    output.must_include("user_priv_changed=True user_removed=True db_removed=True")
    output.must_include("mysql plugins smoke test complete!")
  end

  # The mysql_query/mysql_variables/mysql_info plugins need a live server
  # to exercise; where one isn't reachable the spec pends instead of
  # failing (same convention as the smoke test above). Server 127.0.0.1:13306,
  # root/rootpass - the same credentials test-mysql-quick.yml expects, so
  # the same local server covers both specs.
  it "runs the ad-hoc mysql_query/mysql_variables/mysql_info plugins against a real server (requires a real server at 127.0.0.1:13306)" do
    skip "no MySQL/MariaDB server at 127.0.0.1:13306" unless daemon_reachable?("127.0.0.1", 13306)

    adhoc = File.join(PROJECT_ROOT, "bin", "krikri")
    login = "login_host=127.0.0.1 login_port=13306 login_user=root login_password=rootpass"

    run_adhoc = ->(module_name : String, module_args : String) {
      output = IO::Memory.new
      Process.run(adhoc, ["localhost", "-c", "local", "-i", "localhost,", "-m", "community.mysql." + module_name, "-a", module_args],
        output: output, error: output, chdir: PROJECT_ROOT)
      output.to_s
    }

    output = run_adhoc.call("mysql_query", "#{login} query='CREATE DATABASE IF NOT EXISTS krikri_mysql_spec'")
    output.must_match(/SUCCESS|CHANGED/)

    output = run_adhoc.call("mysql_query", "#{login} query='CREATE TABLE IF NOT EXISTS krikri_mysql_spec.t (id INT PRIMARY KEY, name VARCHAR(50))'")
    output.must_match(/SUCCESS|CHANGED/)

    # login_db must actually be selected on connect - previously dropped
    # entirely, so every unqualified query failed "No database selected".
    output = run_adhoc.call("mysql_query", "#{login} login_db=krikri_mysql_spec query='SELECT * FROM t'")
    output.must_match(/SUCCESS|CHANGED/)

    output = run_adhoc.call("mysql_variables", "#{login} variable=max_connections")
    output.must_match(/SUCCESS|CHANGED/)
    match = output.match(/"msg":\s*"([^"]*)"/)
    match.wont_be_nil
    # The value, not the variable name echoed back.
    (match || raise "unexpected nil")[1].wont_equal("max_connections")

    output = run_adhoc.call("mysql_info", "#{login} filter=version")
    output.must_match(/SUCCESS|CHANGED/)
    version_json = output.match(/"version":\s*\{[^\}]*\}/)
    version_json.wont_be_nil
    parsed = JSON.parse("{#{(version_json || raise "unexpected nil")[0]}}")
    parsed["version"]["full"].as_s.wont_be_empty
    expect(parsed["version"]["suffix"].as_s.starts_with?("-")).must_equal(false)
  end

  it "manages a PostgreSQL database and role (with attribute flag diffing) end to end (requires a real server at 127.0.0.1:15432)" do
    skip "no PostgreSQL server at 127.0.0.1:15432" unless daemon_reachable?("127.0.0.1", 15432)
    status, output = run_playbook(
      "test-postgresql-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-testservers-local.ini")
    )

    status.success?.must_equal(true)
    output.must_include("db_first=True db_idempotent=False")
    output.must_include("db_restore=True db_dump=True db_restore_gz=True")
    output.must_include("restored_count=2")
    output.must_include("db_dump_pgc=True")
    output.must_include("db_restore_pgc=True")
    output.must_include("restored_count_pgc=2")
    output.must_include("user_first=True user_idempotent=False")
    output.must_include("user_flags_changed=True user_removed=True db_removed=True")
    output.must_include("postgresql plugins smoke test complete!")
  end

  it "skips a same-user become entirely, matching real Ansible, and rejects an invalid become_user without shelling out" do
    inventory = File.join(__DIR__, "..", "fixtures", "inventory-testservers-local.ini")
    status, output = run_playbook("test-become-quick.yml", [] of String, inventory: inventory)

    status.success?.must_equal(true)
    output.must_include("bad_user_failed=True")

    # become_user: "{{ current_user.stdout }}" is an escalation to the
    # user already running this process - real Ansible does NOT wrap that
    # in sudo at all (`_low_level_execute_command`'s BECOME_ALLOW_SAME_
    # USER gate), so SUDO_USER is never set in the child. This engine
    # used to wrap it unconditionally, which meant every `become: true`
    # task failed outright on a host with no sudo installed - a minimal
    # container or slimmed cloud image - where real Ansible succeeds.
    output.must_match(/current_user=\S+ became_sudo_user=$/m)
    output.must_include("become smoke test complete!")

    # ANSIBLE_BECOME_ALLOW_SAME_USER is real Ansible's own opt-out from
    # that gate, and forcing it back on is what still exercises the sudo
    # wrapping itself: sudo always sets SUDO_USER in the child when it
    # actually wraps a command, so this only passes if become: really
    # executed the plugin through sudo - not a no-op that happened not to
    # error.
    status, forced = run_playbook(
      "test-become-quick.yml", [] of String, inventory: inventory,
      env: {"ANSIBLE_BECOME_ALLOW_SAME_USER" => "1"}
    )

    status.success?.must_equal(true)
    match = forced.match(/current_user=(\S+) became_sudo_user=(\S+)/)
    match.wont_be_nil
    (match || raise "unexpected nil")[1].must_equal((match || raise "unexpected nil")[2])

    # Real bug found benchmarking geerlingguy.solr's own "Ensure core
    # configuration directories exist." task (become_user: solr,
    # krikri-playbook installed under /root/...): execute_local_plugin
    # always ran the compiled plugin binary straight from wherever
    # krikri-playbook itself lives, which broke the moment that install
    # directory wasn't traversable by become_user (a root-owned
    # /root/... install is a common real-world case) - `sudo: Sorry,
    # user root is not allowed to execute '/root/.../plugins/command'
    # as solr`, really a plain EACCES on /root's own 0700 mode, not an
    # actual sudoers policy denial. A become: task must stage a
    # world-traversable copy of the plugin binary at the staging dir
    # before sudo-ing to it, which the forced run above exercises. The
    # staging dir is the per-user /var/tmp/.krikri-playbook-<user>-<hash>
    # one (PluginManager.remote_plugin_dir) - the old fixed
    # /var/tmp/.krikri-playbook path this used to assert only existed as
    # a stale leftover from a pre-hardening engine on dev machines, so
    # this passed locally and failed on any fresh CI container.
    current_user = (match || raise "unexpected nil")[1]
    staged_command_plugin = File.join(Krikri::PluginManager.remote_plugin_dir(current_user), "command")
    File.exists?(staged_command_plugin).must_equal(true)
    (File.info(staged_command_plugin).permissions.value & 0o777).must_equal(0o755)
  end

  it "keeps register:/set_fact:/include_vars: visible across tasks, and role_defaults from leaking past their own role, through build_vars_context's per-host caching (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #1)" do
    # build_vars_context now caches its per-host-invariant inputs (baseA:
    # play_vars/host.vars/registered_vars; baseB: included_vars/facts/
    # host-magic) behind a shared generation counter instead of
    # rebuilding them from scratch on every task - real risk here is
    # exactly this project's most-repeated bug class (stale/wrong
    # variable visibility), so this exercises every real invalidation
    # path in one sequence on one host: register: visible on the very
    # next task (baseA), set_fact: visible on the very next task (baseB,
    # via @facts), include_vars: visible on the very next task (baseB,
    # via @included_vars), a role's own role_defaults visible during
    # that role but gone again immediately afterward (role_defaults is
    # per-TASK, deliberately NOT part of either cached base), and all 3
    # of the earlier register/fact/include_vars values still correct
    # after the role ran (proving the role's own cache generation bumps
    # - if any - didn't leave a stale base_context_a/b for THIS host).
    status, output = run_playbook(
      "test-vars-context-cache-quick.yml",
      [] of String,
      inventory: hostvars_inventory_file
    )

    status.success?.must_equal(true)
    output.must_include("reg=registered-value")
    output.must_include("fact=from-set-fact")
    output.must_include("included=from-os-family-file")
    output.must_include("after_role_default=MISSING")
    output.must_include("still_visible=reg:registered-value fact:from-set-fact included:from-os-family-file")
    output.must_include("vars_context cache invalidation smoke test complete!")
  end

  it "resolves hostvars['other_host'] to that OTHER host's own inventory vars, both bracket and dot syntax" do
    # Real bug found benchmarking a real geerlingguy.glusterfs 3-node
    # cluster: hostvars wasn't populated in the vars_context at all, so
    # `gluster peer probe {{ hostvars['node2'].ansible_host }}` ran as
    # `gluster peer probe undefined` - silently probing a bogus hostname
    # instead of the real peer's IP. hostvars is also real Ansible's
    # standard way to reference ANY inventory host's own vars from a
    # play that doesn't even target it, not just the current one - a
    # naive fix that only populated hostvars from the current play's
    # own @hosts (rather than the whole inventory) would still miss
    # this exact case, since only node1 runs the peer-probe play in the
    # real playbook that found this bug.
    status, output = run_playbook(
      "test-hostvars-quick.yml",
      [] of String,
      inventory: hostvars_inventory_file
    )

    status.success?.must_equal(true)
    output.must_include("h2_via_bracket=from_h2")
    output.must_include("h2_via_dot=from_h2")
    output.must_include("h1_via_hostvars=from_h1")
    output.must_include("hostvars smoke test complete!")
  end

  it "exposes an implicit hostvars['localhost'] even when the play targets another host" do
    # Regression for round900712 gzm55.require_implicity_localhost: real
    # ansible-core's InventoryManager ALWAYS synthesizes an implicit
    # localhost pseudo-host when no inventory defines one, and any play -
    # even one targeting entirely different machines - can read
    # hostvars['localhost'] (this engine failed with "object of type 'dict'
    # has no attribute 'localhost'"). The inventory fixture here defines no
    # localhost at all; the playbook mirrors the real role's own assert
    # (no inventory_file on the implicit entry) plus the minimal magic var
    # set verified live against ansible-core 2.19.11.
    status, output = run_playbook(
      "test-implicit-localhost-hostvars-quick.yml",
      [] of String,
      inventory: hostvars_inventory_file
    )

    status.success?.must_equal(true)
    output.must_include("implicit localhost hostvars smoke test complete!")
  end

  it "keeps an explicitly inventory-defined localhost's real vars over the implicit entry" do
    # The other half of real Ansible's implicit-localhost contract: when the
    # inventory DOES define localhost, its real entry wins and the
    # synthesized one must not clobber it (verified live against
    # ansible-core 2.19.11 with an identical inventory).
    status, output = run_playbook(
      "test-explicit-localhost-hostvars-quick.yml",
      [] of String,
      inventory: explicit_localhost_plus_h1_inventory
    )

    status.success?.must_equal(true)
    output.must_include("explicit localhost hostvars smoke test complete!")
  end

  it "reflects a register:/set_fact:/meta: clear_facts done by one host in another host's hostvars[...] on the very next task" do
    # Regression for SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #16:
    # build_hostvars/build_groups got memoized per-TaskExecutor (a
    # generation counter bumped on every @facts/@registered_vars
    # mutation) since the unmemoized version was quadratic in host count.
    # This is the invalidation contract's own regression spec, not just a
    # feature test - a naive "cache once, never invalidate" version would
    # pass every OTHER hostvars spec (single-shot reads) but silently
    # serve a stale hostvars['h1'] snapshot here, missing h1's own
    # register:/set_fact:/clear_facts from earlier in the SAME play.
    status, output = run_playbook(
      "test-hostvars-cache-invalidation-quick.yml",
      [] of String,
      inventory: hostvars_inventory_file
    )

    status.success?.must_equal(true)
    output.must_include("got_register=dynamic_h1_value")
    output.must_include("got_fact=fact_value_one")
    output.must_include("cleared=True")
    output.must_include("hostvars cache invalidation smoke test complete!")
  end

  it "resolves groups['group_name'] to that group's member host names, incl. the synthesized 'all'" do
    # Real bug found benchmarking geerlingguy.kubernetes (round 35):
    # `groups` was entirely unpopulated in the vars_context, so ANY
    # `groups[...]` access resolved "undefined" - the role's own "Set
    # the kubeadm join command globally." task (`loop: "{{ groups['all']
    # }}", delegate_to: "{{ item }}"`) turned into a single-item loop
    # whose one item was the literal string "undefined", and the
    # templated delegate_to then tried to SSH to a host literally named
    # "undefined" instead of broadcasting to every real inventory host.
    status, output = run_playbook(
      "test-groups-quick.yml",
      [] of String,
      inventory: File.join(__DIR__, "..", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.must_equal(true)
    output.must_include(%(multilocal_members=['web1', 'web2']))
    output.must_include(%(all_members=['web1', 'web2']))
    output.must_include("groups smoke test complete!")
  end

  it "recovers a failed block: via rescue:, always runs always:, and the play continues" do
    status, output = run_playbook("test-error-handling-quick.yml", [] of String)

    status.success?.must_equal(true)
    output.must_include("block was rescued")
    output.must_include("always runs whether the block failed or not")
    output.must_include("play continues past a rescued block")
    output.must_include("error handling smoke test complete!")
    output.wont_include("SHOULD NOT APPEAR")
    # A successfully-rescued failure shouldn't count against the play.
    output.must_include("rescued=1")
    output.wont_include("failed=1")
  end

  it "halts the rest of the play when a block: fails with no rescue:, but always: still runs, and the process exits non-zero" do
    status, output = run_playbook("test-error-handling-unrescued.yml", [] of String)

    status.success?.must_equal(false)
    output.must_include("always runs regardless")
    output.wont_include("SHOULD NOT APPEAR")
    output.must_include("failed=1")
  end

  it "finds its plugins when invoked from a directory other than its own checkout" do
    # Regression test: PluginManager used to resolve plugins via the
    # cwd-relative path "./bin/plugins/<name>", which only worked if you
    # first `cd`'d into the krikri-playbook checkout - unlike real
    # ansible-playbook, which can be run from anywhere. Running with an
    # unrelated chdir (using absolute paths for everything else) is exactly
    # the scenario that broke.
    status, output = run_playbook("test-debug-quick.yml", ["--check"], chdir: spec_tmp_path)

    status.success?.must_equal(true)
    output.wont_include("Plugin binary not found")
    output.must_include("PLAY RECAP")
  end

  it "runs a plugin against a host with no explicit ansible_user= (regression: Host.from_json crashed on a JSON-null user)" do
    # spec/fixtures/inventory.ini is empty, so "localhost" always takes the
    # separate "implicit localhost" path in InventoryParser#get_hosts,
    # which unconditionally defaults a non-nil user - it never exercises a
    # Host whose user is genuinely nil. An explicitly-declared
    # `localhost ansible_connection=local` (no ansible_user=) does, and is
    # a completely ordinary, common inventory line in the real world.
    status, output = run_playbook("test-debug-quick.yml", [] of String, inventory: EXPLICIT_LOCALHOST_INVENTORY)

    status.success?.must_equal(true)
    output.wont_include("Cast from Nil to String failed")
    output.wont_include("Failed to parse plugin output")
  end

  it "skips plays whose hosts pattern matches nothing in the inventory" do
    status, output = run_playbook("test-command.yml")

    status.success?.must_equal(true)
    output.must_include("Skipping play - no hosts match pattern: testservers")
  end

  it "--limit restricts a hosts: all play to just the named host, not every matching host" do
    # Regression: --limit's value was parsed into a variable that was
    # never actually read anywhere else - krikri-playbook ran hosts: all
    # against the WHOLE inventory regardless of --limit, silently
    # ignoring the flag entirely.
    status, output = run_playbook(
      "test-limit-hosts.yml",
      ["--limit", "hosttwo"],
      inventory: TWO_LOCAL_HOSTS_INVENTORY
    )

    status.success?.must_equal(true)
    output.must_include("ran on hosttwo")
    output.wont_include("ran on hostone")
  end

  it "fires a handler notified by a block: itself when a nested task (with no notify: of its own) changes" do
    # Regression: execute_block/execute_block_multi never checked the
    # enclosing block: task's own notify: at all - only an individual
    # nested task's own notify: was ever forwarded to HandlerRunner.
    status, output = run_playbook("test-block-notify-quick.yml", [] of String)

    status.success?.must_equal(true)
    output.must_include("RUNNING HANDLER")
    output.must_include("handler fired")
  end

  it "parses connection: on a task separately from delegate_to:, and exposes it as ansible_connection for that task" do
    # Regression: `connection:` (distinct from delegate_to: - it changes
    # HOW the task's module runs, not WHICH host's vars/facts apply) was
    # never parsed at all, so it had no effect - robertdebock.backup's
    # own "Create backup_directory" (writes to the controller's
    # filesystem via connection: local, no delegate_to:) silently ran
    # against the real remote target instead, live-reverified fixed on
    # a real Atlantic.net host pair (round 136). Both hosts here are
    # already local-connection either way, so this only proves
    # connection: local is parsed and threaded into the task's own
    # ansible_connection - not that it overrides an otherwise-remote
    # host, which would need a real second SSH-reachable target this
    # spec suite doesn't have (PluginManager's own eager per-play
    # plugin pre-upload pass - see its comment in plugin_manager.cr -
    # is scoped to hosts:, not individual tasks:, so a synthetic
    # unreachable host hangs there before ever reaching this task,
    # regardless of the override).
    status, output = run_playbook(
      "test-connection-local-quick.yml",
      [] of String,
      inventory: TWO_LOCAL_HOSTS_INVENTORY
    )

    status.success?.must_equal(true)
    output.must_include("connection is local")
  end

  it "doesn't crash a task whose when: skips it, even when its own task-level vars: would raise if evaluated (render_task_vars laziness)" do
    # Real bug found benchmarking devsec.hardening.os_hardening: task-
    # level vars: were rendered unconditionally, before when: was even
    # checked, so a vars: expression that legitimately raises (`| first`
    # on a genuinely empty sequence, even with `| default(None)` right
    # after it) crashed the whole task even though when: would have
    # skipped it before real Ansible's own lazy per-key Jinja templating
    # ever touched that expression.
    status, output = run_playbook("test-task-vars-lazy-quick.yml", [] of String)

    status.success?.must_equal(true)
    output.must_include("SUCCESS")
    output.wont_include("should never print")
  end

  # Real Ansible aborts the run at the notifying task, prints one
  # "[ERROR]: The requested handler ... was not found in either the main
  # handlers list nor in the listening handlers list" line and exits 1
  # with no PLAY RECAP - but ONLY when the notification actually fires.
  # Every expectation here was verified against real ansible-core 2.19.4
  # running the equivalent playbook, including the exit codes.
  describe "notify: naming a nonexistent handler" do
    it "aborts the run with rc=1 when a CHANGED task notifies it" do
      write_notify_playbook("notify_missing_changed.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: changes and notifies a missing handler
              ansible.builtin.command: echo hi
              notify: no_such_handler
            - name: after
              ansible.builtin.debug:
                msg: should never be reached
          handlers:
            - name: real handler
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        spec_tmp_path("notify_missing_changed.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.must_equal(1)
      output.must_include("The requested handler 'no_such_handler' was not found in either the main handlers list nor in the listening handlers list")
      output.wont_include("should never be reached")
      output.wont_include("PLAY RECAP")
    end

    it "does not abort when the notifying task is unchanged - real Ansible notifies nothing" do
      write_notify_playbook("notify_missing_unchanged.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: does not change but notifies a missing handler
              ansible.builtin.debug:
                msg: nochange
              notify: no_such_handler
            - name: after
              ansible.builtin.debug:
                msg: reached
          handlers:
            - name: real handler
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        spec_tmp_path("notify_missing_unchanged.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.must_equal(0)
      output.must_include("reached")
      output.wont_include("was not found in either")
    end

    it "does not abort when the notifying task is skipped by its when:" do
      write_notify_playbook("notify_missing_skipped.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: skipped, notifies a missing handler
              ansible.builtin.command: echo hi
              when: false
              notify: no_such_handler
            - name: after
              ansible.builtin.debug:
                msg: reached
          handlers:
            - name: real handler
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        spec_tmp_path("notify_missing_skipped.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.must_equal(0)
      output.must_include("reached")
      output.wont_include("was not found in either")
    end

    it "catches a bad notify inside an include_tasks:-loaded file, which no parse-time sweep can see" do
      # The buluma.phpmyadmin shape (round 181): setup-Debian.yml is
      # pulled in via include_tasks: and notifies `restart apache`, a
      # handler nothing in the role's dependency chain defines. Must not
      # be swallowed into a per-task "Failed to load included tasks"
      # failure either - real Ansible aborts the whole run.
      write_notify_playbook("notify_missing_inner.yml", <<-YAML)
        - name: inner changes and notifies a missing handler
          ansible.builtin.command: echo hi
          notify: restart apache
        YAML

      write_notify_playbook("notify_missing_include.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: include it
              ansible.builtin.include_tasks: notify_missing_inner.yml
            - name: after
              ansible.builtin.debug:
                msg: should never be reached
          handlers:
            - name: Restart httpd
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        spec_tmp_path("notify_missing_include.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.must_equal(1)
      output.must_include("The requested handler 'restart apache' was not found")
      output.wont_include("Failed to load included tasks")
      output.wont_include("should never be reached")
    end

    it "accepts a notify: that matches a handler's listen: topic" do
      write_notify_playbook("notify_listen_topic.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: notify a listen topic
              ansible.builtin.command: echo hi
              notify: webserver restarted
          handlers:
            - name: restart httpd
              listen: webserver restarted
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        spec_tmp_path("notify_listen_topic.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.must_equal(0)
      output.wont_include("was not found in either")
    end

    it "accepts a notify: whose matching handler's own name: is a template" do
      write_notify_playbook("notify_templated_handler.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          vars:
            svc: httpd
          tasks:
            - name: notify the rendered name
              ansible.builtin.command: echo hi
              notify: "Restart httpd"
          handlers:
            - name: "Restart {{ svc }}"
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        spec_tmp_path("notify_templated_handler.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.must_equal(0)
      output.wont_include("was not found in either")
    end

    it "accepts the role-qualified '<qualifier> : <name>' notify: form" do
      write_notify_playbook("notify_role_qualified.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: notify role-qualified
              ansible.builtin.command: echo hi
              notify: "some_role : restart httpd"
          handlers:
            - name: restart httpd
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        spec_tmp_path("notify_role_qualified.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.must_equal(0)
      output.wont_include("was not found in either")
    end
  end

  it "exits non-zero and reports the error for an invalid playbook" do
    bad_playbook = spec_tmp_path("invalid.yml")
    File.write(bad_playbook, "not: a: valid: playbook: [")

    status, output = run_playbook(spec_tmp_path("invalid.yml"))

    status.success?.must_equal(false)
    # Since 0.9.562 a YAML syntax error is reported in real
    # ansible-playbook's own shape rather than this engine's old
    # "Error parsing playbook:" wording - see YamlSyntaxError#render and
    # yaml_syntax_error_spec.cr, which byte-compares the whole block.
    output.must_include("[ERROR]: YAML parsing failed:")
    output.must_include("Origin: ")
    status.exit_code.must_equal(4)

    File.delete(bad_playbook)
  end
end

# Found via a real-host geerlingguy.raspberry-pi round: once a host fails a
# task and gets halted, real ansible-playbook ends the play right there -
# it does not keep printing "TASK [...]" banners for the tasks that follow,
# since there is no host left to run them against.
describe "a notified handler with an empty loop: source" do
  it "is counted as skipped, not ok, matching real ansible-playbook" do
    # Real bug found benchmarking cloudalchemy.cortex's own "reload
    # cortex services" handler (`loop: "{{ cortex_services | dict2items
    # }}"`, empty when cortex_all_in_one: is set): real Ansible skips
    # the whole handler ("All items skipped") and counts it in the
    # recap's skipped= tally. execute_handler_loop previously fell
    # through its own empty loop silently - no "skipping:" line, and
    # record_handler_result's already_displayed branch counted the
    # no-op changed=false/failed=false result as ok instead, inflating
    # ok= by one and undercounting skipped= by one.
    write_notify_playbook("empty_loop_handler_skipped.yml", <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: notify a handler with nothing to loop over
            ansible.builtin.command: echo hi
            notify: reload things
        handlers:
          - name: reload things
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: "{{ [] }}"
      YAML

    status, output = run_playbook(
      spec_tmp_path("empty_loop_handler_skipped.yml"),
      mode_args: [] of String,
      inventory: EXPLICIT_LOCALHOST_INVENTORY,
    )

    status.exit_code.must_equal(0)
    output.must_include("HANDLER [reload things]")
    output.must_include("skipping: [localhost]")
    output.must_include("ok=1")
    output.must_include("skipped=1")
  end
end

describe "a task combining a module with a pre-2.0 legacy directive" do
  it "aborts the whole run with 'conflicting action statements', matching real ansible-playbook" do
    # Real bug found benchmarking nickjj.mariadb/.postgres/.phpfpm, all
    # three independently: an old task carrying both a real module key
    # and a pre-2.0 Ansible top-level attribute (always_run:, sudo_user:,
    # etc.) that was removed a long time ago. Real ansible-core's
    # ModuleArgsParser refuses to even START the run for this
    # ("[ERROR]: conflicting action statements: shell, always_run") -
    # this engine previously just silently ignored the legacy key (or,
    # if it happened to appear first in the YAML, mistook it for the
    # module name outright) and ran the task normally instead. rc=4 (a
    # genuine PARSER error), not rc=1 - verified live against
    # ansible-core 2.19.4 via jdauphant.ssh-config's own equivalent
    # task (RHEL-family round 60105); this spec's own exit_code
    # assertion was wrong (never itself verified live) until then, since
    # this engine's ConflictingActionStatementsError was misclassified
    # as RemovedActionError's rc=1 (the removed-action-PLUGIN case,
    # `include:`, a different real Ansible error class entirely).
    write_notify_playbook("conflicting_action_statements.yml", <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: an old task with a removed legacy directive
            shell: echo hi
            always_run: true
      YAML

    status, output = run_playbook(
      spec_tmp_path("conflicting_action_statements.yml"),
      mode_args: [] of String,
      inventory: EXPLICIT_LOCALHOST_INVENTORY,
    )

    status.exit_code.must_equal(4)
    output.must_include("[ERROR]: conflicting action statements: shell, always_run")
    output.wont_include("PLAY RECAP")
  end
end

describe "a loop_control: loop_var: name in a registered result's own results list" do
  it "is exposed under the custom name too, not just the default 'item'" do
    # Real bug found benchmarking githubixx.containerd's own "Set
    # modprobe_location": `loop_control: { loop_var: path }` on a
    # stat: loop, registered, then `modprobe_locations.results | ... |
    # map(attribute='path')` over the registered results. Each per-
    # iteration result dict only ever got the literal "item" key set
    # (finish_looped_task's own result_hash["item"] = item), regardless
    # of loop_control - a later map(attribute: <custom_name>)/
    # selectattr(<custom_name>, ...) over registered.results always saw
    # that key as missing (null), even though the live execution
    # context correctly bound both names during the loop itself.
    write_notify_playbook("loop_var_in_registered_results.yml", <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: loop with a custom loop_var, registered
            ansible.builtin.debug:
              msg: "{{ path }}"
            loop:
              - a
              - b
            loop_control:
              loop_var: path
            register: looped
          - name: assert the custom name is present in each registered result
            ansible.builtin.assert:
              that:
                - looped.results | map(attribute='path') | list == ['a', 'b']
      YAML

    status, output = run_playbook(
      spec_tmp_path("loop_var_in_registered_results.yml"),
      mode_args: [] of String,
      inventory: EXPLICIT_LOCALHOST_INVENTORY,
    )

    status.exit_code.must_equal(0)
    output.wont_include("FAILED")
  end
end

describe "a halted host after a task failure" do
  it "stops printing TASK banners for tasks after the failure, matching real ansible-playbook" do
    write_notify_playbook("halted_host_no_more_banners.yml", <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: this one fails
            ansible.builtin.fail:
              msg: boom
          - name: should never be reached
            ansible.builtin.debug:
              msg: should never be reached
      YAML

    status, output = run_playbook(
      spec_tmp_path("halted_host_no_more_banners.yml"),
      mode_args: [] of String,
      inventory: EXPLICIT_LOCALHOST_INVENTORY,
    )

    status.exit_code.must_equal(2)
    output.must_include("TASK [this one fails]")
    output.wont_include("TASK [should never be reached]")
    output.wont_include("should never be reached")
  end

  # Regression (0x0i.systemd / kyl191.openvpn, 120-author kata round):
  # tasks inside a when:-false BLOCK of an include_tasks'd role file
  # used to lose their "role : " banner prefix (the skip path printed
  # before role context reached the block's children), and a skipped
  # NAMED meta: task was counted into the PLAY RECAP's skipped where
  # real ansible-core ignores meta tasks in stats entirely.
  it "keeps the role prefix on skipped block children and keeps skipped meta out of the recap" do
    status, output = run_playbook("test-block-skip-prefix.yml")

    status.success?.must_equal(true)
    output.must_include("TASK [block_skip_prefix : Broadcast uninstall signal]")
    output.must_include("TASK [block_skip_prefix : Flush handlers]")
    # only the command task is counted; the skipped meta is not
    output.must_match(/skipped=1/)
  end

  # Regression (buluma.httpd under buluma.roundcubemail / xanmanning.k3s,
  # atlantic round 979000): the multi-host block path printed a
  # when:-false block's children skipping banners before role context
  # reached those children, so banners printed as
  # "TASK [Modify selinux settings]" where real ansible-playbook shows
  # "TASK [buluma.httpd : Modify selinux settings]". The earlier
  # block_skip_prefix fixture only covered the include_tasks: route
  # (which propagates before its own skip printing), never the
  # direct-from-role-tasks route the real roles hit.
  it "keeps the role prefix on skipped block children reached straight from a role's tasks" do
    status, output = run_playbook("test-block-skip-prefix-role.yml")

    status.success?.must_equal(true)
    output.must_include("TASK [skip_block_role_prefix : skipped child]")
    # a block that actually RAN keeps its prefix too (guard against a
    # "fix" that just always adds the prefix on the skip path)
    output.must_include("TASK [skip_block_role_prefix : running child]")
  end
end

describe "an unarchive with a bare relative src" do
  # Regression (wezhai.minio, 120-author kata round): a bare relative
  # `unarchive: src:` (no remote_src, no files/ prefix) must resolve
  # against the role's own files/ dir - real Ansible's unarchive action
  # plugin searches there via _find_needle - and be transferred to the
  # target. Only an ABSOLUTE controller path was staged before, so the
  # plugin got the bare name and failed "Source 'minio.tar.gz' failed
  # to transfer". Runs WITHOUT --check (unarchive can't run in check
  # mode) and needs local tar; the unpacked payload proves the transfer
  # carried the right file. The role's own dest is a unique-per-run
  # mktemp'd scratch dir (self-created and self-cleaning), so a fresh run
  # always reports changed=True here.
  it "resolves a bare relative unarchive src against the role's files/ dir" do
    status, output = run_playbook("test-unarchive-role-files.yml", [] of String)

    status.success?.must_equal(true)
    output.must_include("changed=True failed=False")
  end
end

describe "command: with argv: instead of cmd:/free-form" do
  # Regression (kyl191.openvpn, 120-author kata round): `argv:` (command's
  # list form, real Ansible's own way to avoid shell quoting) fell all
  # the way through to "Missing required parameter: cmd" - the plugin
  # never recognized it as an alternative to cmd:/_raw_params at all, and
  # even once it did, playbook_parser.cr's generic Array param handling
  # comma-joins list values, which would have merged this fixture's own
  # multi-word argv element back into several arguments. Runs WITHOUT
  # --check (command doesn't support check mode).
  it "runs argv:'s exact argument list, preserving a space inside one element as a single arg" do
    status, output = run_playbook("test-command-argv.yml", [] of String)

    status.success?.must_equal(true)
    output.must_include("changed=True failed=False stdout=hello world with spaces")
  end
end

describe "a loop: source referencing an unimplemented filter" do
  # Real crash found in a 150-role overnight round
  # (oasis_roles.system_repositories, which ships its own role-local
  # filter_plugins/exclude.py - a real, understood scope limit, krikri
  # can't execute arbitrary Python filter plugins). The task's `loop:`
  # value referenced that filter; resolve_loop_items_or_raise only
  # rescued UndefinedVariableError, so the FilterEngine's
  # UnknownFilterError propagated all the way out of Executor#run
  # unrescued and crashed the ENTIRE krikri-playbook process -
  # "Unhandled exception: No filter named '...'." - losing every other
  # host/task the run would otherwise have completed, not just failing
  # this one task the way real Ansible's own AnsibleFilterError would.
  it "fails only the task, not the whole process" do
    status, output = run_playbook("test-loop-unknown-filter.yml", [] of String)

    status.success?.must_equal(true)
    output.wont_include("Unhandled exception")
    output.must_include("No filter named 'totally_unimplemented_filter_xyz'")
    output.must_include("survived changed=False failed=False")
  end
end

describe "include_vars: with register:" do
  # Real bug found in a 150-role overnight round (pacifica.
  # ansible_pacifica): `include_vars: "defaults/{{ item }}.yml"
  # register: vars_result loop: "{{ pacifica_enabled_services }}"`,
  # then a later task reads `vars_result.results |
  # items2dict(key_name='item', value_name='ansible_facts')`.
  # parse_include_vars_task - a dedicated parser separate from the
  # generic #parse_task every other module goes through - never called
  # the line that sets task.register at all, so include_vars: silently
  # dropped `register:` regardless of whether the task was looped;
  # `vars_result` stayed entirely unbound and any later reference
  # raised "'vars_result.results' is undefined". Fixed for both the
  # looped (`.results` array, matching the generic looped-task register
  # shape) and non-looped (`ansible_facts:`, matching real Ansible's own
  # include_vars module result) cases.
  it "populates register: for both a looped and a non-looped include_vars:" do
    status, output = run_playbook("test-include-vars-register.yml", [] of String)

    status.success?.must_equal(true)
    output.must_include("web_port=80 db_port=5432")
    output.must_include("single_ansible_facts_port=80")
  end
end
