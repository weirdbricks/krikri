require "../spec_helper"

# lvol's parameter-validation failures - exercised before any vgs/lvs
# call, so they don't need an LVM stack. Anything past validation needs
# real volume groups and belongs to the live benchmark rounds, not the
# unit/integration suite.
describe "lvol plugin" do
  it "fails when vg is missing" do
    result = PluginSpecHelper.run("lvol", {"lv" => "test", "size" => "512"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("vg")
  end

  it "fails when neither lv nor thinpool is given" do
    result = PluginSpecHelper.run("lvol", {"vg" => "vg0", "size" => "512"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("one of the following is required")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("lvol", {"vg" => "vg0", "lv" => "test", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("state must be 'present' or 'absent'")
  end

  it "fails on a bad size specification before touching LVM" do
    result = PluginSpecHelper.run("lvol", {"vg" => "vg0", "lv" => "test", "size" => "abc"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Bad size specification of 'abc'")
  end

  it "fails on a percentage above 100 before touching LVM" do
    result = PluginSpecHelper.run("lvol", {"vg" => "vg0", "lv" => "test", "size" => "150%VG"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Size percentage cannot be larger than 100%")
  end

  it "fails on %ORIGIN without a snapshot" do
    result = PluginSpecHelper.run("lvol", {"vg" => "vg0", "lv" => "test", "size" => "100%ORIGIN"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Percentage of ORIGIN supported only for snapshot volumes")
  end
end
