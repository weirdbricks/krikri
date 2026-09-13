require "../spec_helper"

# Ad-hoc CLI comparison sweep vs real ansible (2026-09-13): verified live
# against community.general.capabilities (12.5.0, ansible-core 2.19) -
# the changed path returns changed/state/msg("capabilities changed")/
# stdout (setcap output, normally empty), the unchanged path returns ONLY
# changed+state (no msg at all, no stdout).

describe "capabilities plugin result shape" do
  # The state=present unchanged path needs the capability already set
  # (setcap requires CAP_SETFCAP), so this exercises the same
  # `exit_json(changed=False, state=...)` exit via state=absent on a file
  # that doesn't have the capability - the identical result shape.
  it "returns only changed+state (no msg, no stdout) on the unchanged path" do
    path = File.tempname("capabilities-unchanged")
    File.write(path, "")

    result = PluginSpecHelper.run("capabilities", {
      "path" => path, "capability" => "cap_chown+eip", "state" => "absent",
    })

    result["changed"].as_bool.should be_false
    result["state"].as_s.should eq("absent")
    result["msg"]?.should be_nil
    result["stdout"]?.should be_nil
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "returns changed/state/msg/stdout on the changed path (needs CAP_SETFCAP)" do
    probe = File.tempname("capabilities-probe")
    File.write(probe, "")
    setcap_ok = Process.run("setcap", ["cap_chown+eip", probe]).success?
    File.delete(probe)
    pending! "needs CAP_SETFCAP (setcap not permitted in this environment)" unless setcap_ok

    path = File.tempname("capabilities-changed")
    File.write(path, "")

    result = PluginSpecHelper.run("capabilities", {
      "path" => path, "capability" => "cap_chown+eip", "state" => "present",
    })

    result["changed"].as_bool.should be_true
    result["state"].as_s.should eq("present")
    result["msg"].as_s.should eq("capabilities changed")
    result["stdout"].as_s.should be_empty
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
