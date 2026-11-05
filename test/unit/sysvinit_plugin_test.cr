require "../minitest_helper"
require "file_utils"

# Regression spec for plugins/sysvinit.cr (ansible.builtin.sysvinit,
# issue #900): the module used to take the graceful unavailable-module
# skip, where real runs it - its AnsibleModule init fails on the
# required_one_of [['state', 'enabled']] check for a name:-only task
# (kpg's sysvinit chaos shape), and its run covers SysV enable/disable
# plus the init-script state actions.
#
# Shape facts pinned here (live-verified vs ansible-playbook 2.19.11 on
# this host with a fake init script driven by an absolute-path name -
# the module's get_sysv_script uses such a name verbatim):
# - a missing init script fails with fail_if_missing's exact wording,
#   INCLUDING the trailing ": " the module's empty extra leaves behind;
# - status detection goes through `service <name> status` when the
#   service binary exists, and its rc/output heuristics decide
#   is_started (an rc in 1/2/3/4/69 counts as "worked" but NOT started);
# - the result's status dict ALWAYS carries an "enabled" entry, then the
#   raw state string - or Python's None key, serialized as "null", when
#   no state: was given;
# - a state action's failure carries the runme kwargs (rc/stdout/stderr)
#   with "Failed to <action> service: <name>".
describe "sysvinit plugin" do
  # Fake init script: status/start/stop controlled by marker files, so
  # every run is deterministic without touching any real service. (An
  # unescaped heredoc is safe here: Crystal only interpolates #{...},
  # and the script's $vars/$() stay literal.)
  FAKE_INIT = <<-SH
    #!/bin/sh
    dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    state="$dir/state"
    case "$1" in
      status)
        if [ -f "$state/running" ]; then echo "fakesvc is running"; exit 0; fi
        echo "fakesvc is stopped"
        exit 3 ;;
      start)
        if [ -f "$state/fail_start" ]; then
          echo "start blew up"
          echo "start err line" >&2
          exit 1
        fi
        touch "$state/running"
        echo "Starting fakesvc" ;;
      stop)
        rm -f "$state/running"
        echo "Stopping fakesvc" ;;
      restart|reload) ;;
      *) echo "Usage: $0 {start|stop|status|restart|reload}"; exit 2 ;;
    esac
    exit 0
    SH

  private def with_fake_init(&)
    dir = PluginSpecHelper.tmp_path("sysvinit-fake")
    state_dir = File.join(dir, "state")
    FileUtils.mkdir_p(state_dir)
    init = File.join(dir, "fakesvc-init")
    File.write(init, FAKE_INIT)
    File.chmod(init, 0o755)
    yield dir, init, state_dir
  ensure
    FileUtils.rm_rf(dir) if dir.is_a?(String)
  end

  it "fails a missing init script with fail_if_missing's exact wording" do
    result = PluginSpecHelper.run("sysvinit", {
      "name"  => "definitely-not-a-service-krikri-900",
      "state" => "started",
    })
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(
      "Could not find the requested service definitely-not-a-service-krikri-900: ")
  end

  # A decoy process whose ps line carries a unique token: the module's
  # pattern: path finds is_started purely in `ps auxww` output (the
  # status command is skipped), which is the only deterministic way a
  # test can present a "running" service - a path-name service's own
  # `service <path> status` probe returns rc 4 with no output (real
  # ansible sees the same), so the keyword heuristics can never see a
  # fake script's status text through it.
  private DECOY_PATTERN = "krikri900probe"

  private def with_decoy_process(&)
    decoy = Process.new("/bin/bash", ["-c", "exec -a #{DECOY_PATTERN} sleep 30"])
    yield
  ensure
    decoy.try(&.terminate) if decoy
  end

  it "reports a pattern-matched running service unchanged for state=started" do
    with_fake_init do |_, init, _|
      with_decoy_process do
        result = PluginSpecHelper.run("sysvinit", {
          "name"    => init,
          "state"   => "started",
          "pattern" => DECOY_PATTERN,
        })
        result["failed"]?.must_be_nil
        result["changed"].as_bool.must_equal(false)
        status = result["status"].as_h
        status.has_key?("started").must_equal(true)
        started = status["started"].as_h
        started["changed"].as_bool.must_equal(false)
        started["rc"].raw.must_be_nil
        started["stdout"].raw.must_be_nil
        started["stderr"].raw.must_be_nil
        enabled = status["enabled"].as_h
        enabled["changed"].as_bool.must_equal(false)
        enabled["rc"].raw.must_be_nil
      end
    end
  end

  it "stops a pattern-matched running service" do
    with_fake_init do |_, init, state_dir|
      File.touch(File.join(state_dir, "running"))
      with_decoy_process do
        result = PluginSpecHelper.run("sysvinit", {
          "name"    => init,
          "state"   => "stopped",
          "pattern" => DECOY_PATTERN,
        })
        result["changed"].as_bool.must_equal(true)
        stopped = result["status"].as_h["stopped"].as_h
        stopped["changed"].as_bool.must_equal(true)
        stopped["rc"].as_i.must_equal(0)
        stopped["stdout"].as_s.must_equal("Stopping fakesvc\n")
        File.exists?(File.join(state_dir, "running")).must_equal(false)
      end
    end
  end

  it "starts a stopped service and reports the runme output" do
    with_fake_init do |_, init, state_dir|
      result = PluginSpecHelper.run("sysvinit", {
        "name"  => init,
        "state" => "started",
      })
      result["changed"].as_bool.must_equal(true)
      started = result["status"].as_h["started"].as_h
      started["changed"].as_bool.must_equal(true)
      started["rc"].as_i.must_equal(0)
      started["stdout"].as_s.must_equal("Starting fakesvc\n")
      started["stderr"].as_s.must_equal("")
      File.exists?(File.join(state_dir, "running")).must_equal(true)
    end
  end

  it "treats a status rc in the module's known-bad set as worked-but-stopped" do
    # The fake script's status exits 3 ("fakesvc is stopped") - the
    # output heuristic already matched "stop", so this also pins that
    # the stop word wins over the rc fallback.
    with_fake_init do |_, init, state_dir|
      result = PluginSpecHelper.run("sysvinit", {
        "name"  => init,
        "state" => "stopped",
      })
      # A stopped service stays stopped: neither elif branch runs.
      result["changed"].as_bool.must_equal(false)
      File.exists?(File.join(state_dir, "running")).must_equal(false)
    end
  end

  it "fails the task with the runme kwargs when the init script verb exits non-zero" do
    with_fake_init do |_, init, state_dir|
      File.touch(File.join(state_dir, "fail_start"))
      result = PluginSpecHelper.run("sysvinit", {
        "name"  => init,
        "state" => "started",
      })
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to start service: #{init}")
      result["rc"].as_i.must_equal(1)
      result["stdout"].as_s.must_equal("start blew up\n")
      result["stderr"].as_s.must_equal("start err line\n")
    end
  end

  it "reports a would-be change in check mode without running the init script" do
    with_fake_init do |_, init, state_dir|
      result = PluginSpecHelper.run("sysvinit", {
        "name"                => init,
        "state"               => "started",
        "_ansible_check_mode" => "true",
      })
      result["changed"].as_bool.must_equal(true)
      started = result["status"].as_h["started"].as_h
      started["changed"].as_bool.must_equal(true)
      started["rc"].raw.must_be_nil
      File.exists?(File.join(state_dir, "running")).must_equal(false)
    end
  end

  it "keys the state section as null (Python's None key) when no state: was given" do
    with_fake_init do |_, init, _|
      # enabled=false against a path-name service: the rc?.d glob for a
      # name containing slashes never matches, so no enable change - and
      # the status dict must still carry the "null" state entry.
      result = PluginSpecHelper.run("sysvinit", {
        "name"    => init,
        "enabled" => "false",
      })
      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      status = result["status"].as_h
      status.has_key?("enabled").must_equal(true)
      status.has_key?("null").must_equal(true)
      status["null"].as_h["changed"].as_bool.must_equal(false)
    end
  end
end
