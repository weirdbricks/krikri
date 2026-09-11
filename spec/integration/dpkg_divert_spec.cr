require "../spec_helper"

# dpkg_divert's parameter-validation failures, exercised before anything
# shells out. The read-only status check below only runs when dpkg-divert
# itself is installed; actually adding/removing a diversion mutates the
# real dpkg database and belongs to the live benchmark rounds.
describe "dpkg_divert plugin" do
  it "fails when path is missing" do
    result = PluginSpecHelper.run("dpkg_divert", {"state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("path")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("dpkg_divert", {"path" => "/etc/hosts", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("state must be 'present' or 'absent'")
  end

  it "reports an unmodified absence for a never-diverted path", tags: "needs_dpkg" do
    next unless File.exists?("/usr/bin/dpkg-divert") || File.exists?("/usr/sbin/dpkg-divert")

    result = PluginSpecHelper.run("dpkg_divert", {"path" => "/etc/hostname", "state" => "absent"})

    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
  end
end
