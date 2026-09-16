require "../spec_helper"

# Pins plugins/lvol.cr's AnsibleModule argument-validation surface
# against real community.general.lvol (live-diffed via the podman-diff
# lvol_edge_cases harness; real LVM mutation testing is infeasible
# there - a PV needs a loop device the host owns and rootless podman
# EPERMs the /dev/loop-control ioctl even with --privileged - so this
# pins the setup-time validation surface and the vgs-backed VG-absent
# discovery path, which the harness's lvm2 install makes reachable).
# Previously the wording was hand-rolled and singular
# ("missing required argument: vg"), the argspec check didn't exist
# (LV3), state also accepted non-real choices (LV5), bool params weren't
# type-validated (LV4), and state=absent against a missing VG invented
# a "Volume group ... does not exist." msg real never prints (LV7).
describe "lvol plugin argument validation" do
  it "fails a missing vg with the sorted plural wording (LV1)" do
    result = PluginSpecHelper.run("lvol", {"lv" => "krikri-lv", "size" => "4"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: vg")
  end

  it "fails with real's one-of wording when neither lv nor thinpool is given (LV2)" do
    result = PluginSpecHelper.run("lvol", {"vg" => "krikri-vg", "size" => "4"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("one of the following is required: lv, thinpool")
  end

  it "rejects out-of-spec parameters with real's supported-list wording (LV3)" do
    result = PluginSpecHelper.run("lvol", {"vg" => "krikri-vg", "lv" => "krikri-lv",
                                           "size" => "4", "krikri_not_an_lvol_param" => "true"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.general.lvol) module: krikri_not_an_lvol_param. " \
                                 "Supported parameters include: active, force, lv, opts, pvs, resizefs, shrink, " \
                                 "size, snapshot, state, thinpool, vg.")
  end

  it "fails a non-boolean bool-typed param with parameters.py wording (LV4)" do
    result = PluginSpecHelper.run("lvol", {"vg" => "krikri-vg", "lv" => "krikri-lv",
                                           "size" => "4", "force" => "sometimes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'force' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'sometimes' is not a valid boolean.  Valid booleans include: ")
  end

  it "rejects a state outside real's [absent, present] choice list (LV5)" do
    result = PluginSpecHelper.run("lvol", {"vg" => "krikri-vg", "lv" => "krikri-lv", "state" => "mounted"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: absent, present, got: mounted")
  end

  it "exits ok with changed=false and NO msg for state=absent against a missing VG (LV7)" do
    result = PluginSpecHelper.run("lvol", {"vg" => "krikri-lvol-nosuch-vg", "lv" => "krikri-lv", "state" => "absent"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_false
    result["msg"]?.should be_nil
  end

  it "still fails state=present against a missing VG with real's discovery wording (LV6)" do
    result = PluginSpecHelper.run("lvol", {"vg" => "krikri-lvol-nosuch-vg", "lv" => "krikri-lv", "size" => "4"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Volume group krikri-lvol-nosuch-vg does not exist.")
  end
end
