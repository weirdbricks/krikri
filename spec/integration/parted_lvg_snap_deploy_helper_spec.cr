require "../spec_helper"

# parted/lvg/snap/deploy_helper parameter-validation paths - exercised
# before any state-mutating command, so they need none of parted/LVM/
# snapd/a deploy tree. Anything past validation needs real block
# devices, a volume group, snapd, or a deployed tree and belongs to the
# live benchmark rounds, not this suite.
describe "parted plugin" do
  it "fails when device is missing" do
    result = PluginSpecHelper.run("parted", {"number" => "1"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("device")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/sdz99", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, info, got: bogus")
  end

  it "fails on an invalid unit" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/sdz99", "unit" => "furlongs"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of unit must be one of")
  end

  it "fails on a missing device before any mutation" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/krikri-no-such-disk"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Could not stat device")
  end
end

describe "lvg plugin" do
  it "fails when vg is missing" do
    result = PluginSpecHelper.run("lvg", {"pvs" => "/dev/sdz99"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("missing required arguments: vg")
  end

  it "fails when pvs is missing for state=present" do
    result = PluginSpecHelper.run("lvg", {"vg" => "krikri-nosuch-vg"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("state is present but all of the following are missing: pvs")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("lvg", {"vg" => "vg0", "pvs" => "/dev/sdz99", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, got: bogus")
  end

  it "rejects unsupported parameters like real AnsibleModule" do
    result = PluginSpecHelper.run("lvg", {"vg" => "vg0", "pvs" => "/dev/sdz99", "bogus_param" => "1"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Unsupported parameters for (community.general.lvg) module: bogus_param")
  end
end

describe "snap plugin" do
  it "fails when name is missing" do
    result = PluginSpecHelper.run("snap", {"state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("missing required arguments: name")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("snap", {"name" => "hello-world", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, enabled, disabled, got: bogus")
  end

  it "fails when the snap binary is missing" do
    result = PluginSpecHelper.run("snap", {"name" => "hello-world"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Failed to find required executable \"snap\"")
  end
end

describe "deploy_helper plugin" do
  it "fails when path is missing" do
    result = PluginSpecHelper.run("deploy_helper", {"state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("missing required arguments: path")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("deploy_helper", {"path" => "/tmp/krikri-deploy-test", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: finalize, absent, clean, present, query, unfinished, got: bogus")
  end

  it "fails when release is missing for state=unfinished" do
    result = PluginSpecHelper.run("deploy_helper", {"path" => "/tmp/krikri-deploy-test", "state" => "unfinished"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("state is unfinished but all of the following are missing: release")
  end

  it "query returns an empty release list for a nonexistent tree" do
    result = PluginSpecHelper.run("deploy_helper",
      {"path" => "/tmp/krikri-deploy-nosuch", "state" => "query"})

    result["failed"]?.should be_nil
    result["releases"].as_a.size.should eq(0)
  end
end
