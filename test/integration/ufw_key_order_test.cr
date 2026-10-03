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
