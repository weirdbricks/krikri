require "../spec_helper"

# yum_versionlock only makes sense against a real RHEL-family host with
# yum-plugin-versionlock installed - this dev/CI box has no /usr/bin/yum
# at all, so only the "yum missing" failure path is exercisable here.
# The rest of the plugin (NEVRA matching against real `yum versionlock
# list` output, add/delete changed semantics) needs live verification on
# a real yum host - same accommodation as the dnf_versionlock spec.
private YUM = "/usr/bin/yum"

describe "yum_versionlock plugin" do
  it "fails cleanly when yum is not installed" do
    result = PluginSpecHelper.run("yum_versionlock", {"name" => "nginx", "state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("yum")
  end

  it "locks a package idempotently and unlocks it again" do
    pending! "no yum on this host" unless File.exists?(YUM)

    result = PluginSpecHelper.run("yum_versionlock", {"name" => "bash", "state" => "present"})
    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_true
    result["meta"]["packages"].as_a.should contain("bash")
    result["meta"]["state"].as_s.should eq("present")

    result = PluginSpecHelper.run("yum_versionlock", {"name" => "bash", "state" => "present"})
    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_false

    result = PluginSpecHelper.run("yum_versionlock", {"name" => "bash", "state" => "absent"})
    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_true

    result = PluginSpecHelper.run("yum_versionlock", {"name" => "bash", "state" => "absent"})
    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_false
  end

  # Check mode runs `yum versionlock list` (the real module only skips
  # the mutating add/delete) but must claim the change without mutating
  # anything - a spec no installed package could ever satisfy keeps this
  # independent of the host's current locklist state.
  it "check mode claims the change without mutating the locklist" do
    pending! "no yum on this host" unless File.exists?(YUM)

    result = PluginSpecHelper.run("yum_versionlock", {
      "name"                => "krikri-spec-nopkg",
      "state"               => "present",
      "_ansible_check_mode" => "true",
    })
    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_true
    result["meta"]["packages"].as_a.should contain("krikri-spec-nopkg")

    result = PluginSpecHelper.run("yum_versionlock", {
      "name"                => "krikri-spec-nopkg",
      "state"               => "absent",
      "_ansible_check_mode" => "true",
    })
    result["failed"]?.should be_nil
    result["changed"].as_bool.should be_false
  end
end
