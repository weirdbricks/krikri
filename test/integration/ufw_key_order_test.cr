require "../minitest_helper"
require "file_utils"

# Regression spec for the ufw plugin's registered-result KEY ORDER and
# key SET, pinned against real community.general.ufw on a real Ubuntu
# 22.04 host (krikri-role-tester round 992002, kop_firewall probes; the
# real side of those captures is the oracle here).
#
# Real ufw.py's exit shape (from its own source): every normal-mode exit
# is exit_json(changed=changed, commands=cmds, msg=post_state.rstrip())
# - msg is the FINAL `ufw status verbose` snapshot, never the ufw action
# command's own output - while check mode returns
# exit_json(changed=changed, commands=cmds) with NO msg key at all. The
# controller backfills `failed` last, so the registered orders are
# [changed, commands, msg, failed] and [changed, commands, failed].
#
# The ufw binary is shimmed here: ufw itself needs working netfilter
# (CAP_NET_ADMIN) even for `status`, which rootless test environments
# don't have - the command-level behavior is pinned by
# test/unit/ufw_command_test.cr and the round-992002 real-host capture,
# this spec pins only the result shape.

private def with_ufw_shims(&)
  dir = File.join(Dir.tempdir, "krikri-ufw-keyorder-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "ufw"), <<-'SHIM')
    #!/bin/sh
    case "$*" in
      *status*) echo "Status: inactive" ;;
      --version*) echo "ufw 0.36.2" ;;
      *) echo "Rules updated"; echo "Rules updated (v6)" ;;
    esac
  SHIM
  File.chmod(File.join(dir, "ufw"), 0o755)
  env = {"PATH" => "#{dir}:/usr/bin:/bin"}.to_json
  yield env
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "ufw plugin registered-result key order (real round-992002 shape)" do
  it "serializes a normal-mode rule task as changed-commands-msg (failed backfilled last)" do
    with_ufw_shims do |env|
      result = PluginSpecHelper.run("ufw", {
        "rule"         => "allow",
        "port"         => "8080",
        "proto"        => "tcp",
        "_environment" => env,
      })

      result["failed"]?.must_be_nil
      result.as_h.keys.must_equal(["changed", "commands", "msg"])
      # msg is the final `ufw status verbose` snapshot rstripped, not the
      # rule command's own output.
      result["msg"].as_s.must_equal("Status: inactive")
      result["commands"].as_a.map(&.as_s).any?(&.includes?("status verbose")).must_equal(true)
    end
  end

  it "serializes a check-mode rule task as changed-commands with NO msg key" do
    with_ufw_shims do |env|
      result = PluginSpecHelper.run("ufw", {
        "rule"                => "allow",
        "port"                => "8081",
        "proto"               => "tcp",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.must_be_nil
      result["msg"]?.must_be_nil
      result.as_h.keys.must_equal(["changed", "commands"])
    end
  end

  it "serializes a normal-mode state task as changed-commands-msg with the status snapshot as msg" do
    with_ufw_shims do |env|
      result = PluginSpecHelper.run("ufw", {
        "state"        => "disabled",
        "_environment" => env,
      })

      result["failed"]?.must_be_nil
      result.as_h.keys.must_equal(["changed", "commands", "msg"])
      result["msg"].as_s.must_equal("Status: inactive")
    end
  end

  it "serializes a check-mode state task as changed-commands with NO msg key" do
    with_ufw_shims do |env|
      result = PluginSpecHelper.run("ufw", {
        "state"               => "disabled",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.must_be_nil
      result["msg"]?.must_be_nil
      result.as_h.keys.must_equal(["changed", "commands"])
    end
  end
end

# Value-level pins against the round-995002 real-host captures
# (kop_firewall probes, atlantic_local): the registered `commands` list
# is real ufw.py's exact execution trace - pre `status verbose` + rule
# tuples grep, `ufw --version` before every rule command, `ufw -f <verb>`
# for state commands, post `status verbose` + tuples grep whenever the
# tail's pre/post diff decides `changed` - and `msg` is the final
# `ufw status verbose` snapshot. The ufw/grep shims below are stateful
# (the allow/delete shims mutate a tuple file the grep shim serves back)
# so the changed values fall out of the same pre/post diffing real does.
private def with_ufw_state_shims(&)
  dir = File.join(Dir.tempdir, "krikri-ufw-cmds-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  state = File.join(dir, "tuples")
  File.write(state, "")
  ufw = File.join(dir, "ufw")
  grep = File.join(dir, "grep")
  File.write(ufw, <<-SHIM)
    #!/bin/sh
    STATE="$KRIKRI_UFW_STATE"
    if [ "$1" = "status" ]; then echo "Status: inactive"; exit 0; fi
    if [ "$1" = "--version" ]; then echo "ufw 0.36.2"; exit 0; fi
    DRY=""
    if [ "$1" = "--dry-run" ]; then DRY=1; shift; fi
    if [ "$1" = "-f" ]; then
      shift
      echo "Firewall skipped (simulated)"
      exit 0
    fi
    if [ "$1" = "delete" ]; then
      shift
      if grep -qF "### tuple $*" "$STATE"; then
        # `;` not `&&`: deleting the LAST rule makes `grep -vF` select
        # nothing and exit 1, which would short-circuit an `&&` chain
        # and leave the tuple in the state file - so the delete would
        # read as a no-op and changed would come back false.
        grep -vF "### tuple $*" "$STATE" > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"
        echo "Rule deleted"
      else
        echo "Could not delete non-existent rule"
      fi
      exit 0
    fi
    if grep -qF "### tuple $*" "$STATE"; then
      echo "Skipping adding existing rule"
    elif [ -n "$DRY" ]; then
      echo "Rules updated"
      echo "Rules updated (v6)"
      cat "$STATE"
      echo "### tuple $*"
    else
      echo "### tuple $*" >> "$STATE"
      echo "Rule added"
    fi
    exit 0
    SHIM
  File.write(grep, <<-SHIM)
    #!/bin/sh
    if [ "$1" = "-h" ]; then
      shift
      [ -s "$KRIKRI_UFW_STATE" ] && cat "$KRIKRI_UFW_STATE"
      exit 0
    fi
    exec /bin/grep "$@"
    SHIM
  File.chmod(ufw, 0o755)
  File.chmod(grep, 0o755)
  env = {"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_UFW_STATE" => state}.to_json
  yield env, "#{dir}/ufw", "#{dir}/grep"
ensure
  FileUtils.rm_rf(dir) if dir
end

private def ufw_expected_commands(ufw_bin : String, grep_bin : String, middle : Array(String)) : Array(String)
  grep_cmd = "#{grep_bin} -h '^### tuple' /lib/ufw/user.rules /lib/ufw/user6.rules /etc/ufw/user.rules /etc/ufw/user6.rules /var/lib/ufw/user.rules /var/lib/ufw/user6.rules"
  pre = ["#{ufw_bin} status verbose", grep_cmd]
  post = ["#{ufw_bin} status verbose", grep_cmd]
  pre + middle + post
end

describe "ufw plugin registered commands list (real round-995002 values)" do
  it "state=disabled records status-grep--f disable-status-grep and msg is the status snapshot" do
    with_ufw_state_shims do |env, ufw_bin, grep_bin|
      result = PluginSpecHelper.run("ufw", {"state" => "disabled", "_environment" => env})

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Status: inactive")
      result["commands"].as_a.map(&.as_s).must_equal(ufw_expected_commands(ufw_bin, grep_bin, ["#{ufw_bin} -f disable"]))
    end
  end

  it "state=disabled in check mode stops after the pre probes" do
    with_ufw_state_shims do |env, ufw_bin, grep_bin|
      result = PluginSpecHelper.run("ufw", {"state" => "disabled", "_ansible_check_mode" => "true", "_environment" => env})

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["msg"]?.must_be_nil
      grep_cmd = "#{grep_bin} -h '^### tuple' /lib/ufw/user.rules /lib/ufw/user6.rules /etc/ufw/user.rules /etc/ufw/user6.rules /var/lib/ufw/user.rules /var/lib/ufw/user6.rules"
      result["commands"].as_a.map(&.as_s).must_equal(["#{ufw_bin} status verbose", grep_cmd])
    end
  end

  it "a fresh rule allow records --version, the rule command, and the post probes" do
    with_ufw_state_shims do |env, ufw_bin, grep_bin|
      result = PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "_environment" => env})

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Status: inactive")
      result["commands"].as_a.map(&.as_s).must_equal(ufw_expected_commands(ufw_bin, grep_bin, [
        "#{ufw_bin} --version",
        "#{ufw_bin} allow from any to any port 8080 proto tcp",
      ]))
    end
  end

  it "a re-applied identical rule records the same trace with changed=false" do
    with_ufw_state_shims do |env, ufw_bin, grep_bin|
      PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "_environment" => env})
      result = PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "_environment" => env})

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Status: inactive")
      result["commands"].as_a.map(&.as_s).must_equal(ufw_expected_commands(ufw_bin, grep_bin, [
        "#{ufw_bin} --version",
        "#{ufw_bin} allow from any to any port 8080 proto tcp",
      ]))
    end
  end

  it "a check-mode rule records --version and the --dry-run command, with no post probes" do
    with_ufw_state_shims do |env, ufw_bin, grep_bin|
      PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "_environment" => env})
      result = PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8081", "proto" => "tcp", "_ansible_check_mode" => "true", "_environment" => env})

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"]?.must_be_nil
      grep_cmd = "#{grep_bin} -h '^### tuple' /lib/ufw/user.rules /lib/ufw/user6.rules /etc/ufw/user.rules /etc/ufw/user6.rules /var/lib/ufw/user.rules /var/lib/ufw/user6.rules"
      result["commands"].as_a.map(&.as_s).must_equal([
        "#{ufw_bin} status verbose",
        grep_cmd,
        "#{ufw_bin} --version",
        "#{ufw_bin} --dry-run allow from any to any port 8081 proto tcp",
      ])
    end
  end

  it "a check-mode rule that already exists reports changed=false" do
    with_ufw_state_shims do |env, _, _|
      PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "_environment" => env})
      result = PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "_ansible_check_mode" => "true", "_environment" => env})

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
    end
  end

  it "a rule delete records --version, the delete command, and the post probes" do
    with_ufw_state_shims do |env, ufw_bin, grep_bin|
      PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "_environment" => env})
      result = PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "delete" => "true", "_environment" => env})

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Status: inactive")
      result["commands"].as_a.map(&.as_s).must_equal(ufw_expected_commands(ufw_bin, grep_bin, [
        "#{ufw_bin} --version",
        "#{ufw_bin} delete allow from any to any port 8080 proto tcp",
      ]))
    end
  end

  it "a second delete of the same rule reports changed=false with the same trace" do
    with_ufw_state_shims do |env, ufw_bin, grep_bin|
      PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "_environment" => env})
      PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "delete" => "true", "_environment" => env})
      result = PluginSpecHelper.run("ufw", {"rule" => "allow", "port" => "8080", "proto" => "tcp", "delete" => "true", "_environment" => env})

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Status: inactive")
      result["commands"].as_a.map(&.as_s).must_equal(ufw_expected_commands(ufw_bin, grep_bin, [
        "#{ufw_bin} --version",
        "#{ufw_bin} delete allow from any to any port 8080 proto tcp",
      ]))
    end
  end

  it "an invalid rule value fails with real's validation shape and no commands" do
    with_ufw_state_shims do |env, _, _|
      result = PluginSpecHelper.run("ufw", {"rule" => "kop_bogus_rule", "_environment" => env})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("value of rule must be one of: allow, deny, limit, reject, got: kop_bogus_rule")
      result["changed"].as_bool.must_equal(false)
      result["exception"].as_s.must_equal("(traceback unavailable)")
      result["commands"]?.must_be_nil
    end
  end
end
