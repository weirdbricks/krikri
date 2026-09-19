require "../spec_helper"

# community.general.yum_versionlock argument-validation order: real
# AnsibleModule validates required/choices at construction, BEFORE the
# module resolves the yum binary or runs `yum versionlock list` - so an
# invalid invocation fails with the argument-spec message even on a host
# without yum (same order the dnf_versionlock sibling implements, see
# alternatives_validation_spec.cr's own block).
describe "yum_versionlock validation order" do
  it "fails with the required-arguments message when name is missing" do
    result = PluginSpecHelper.run("yum_versionlock", {"state" => "present"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "fails with the choices message for an invalid state, before the yum binary check" do
    result = PluginSpecHelper.run("yum_versionlock", {
      "name"  => "bash",
      "state" => "krikri_state",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, got: krikri_state")
  end

  it "still fails on the missing yum binary for a valid invocation" do
    result = PluginSpecHelper.run("yum_versionlock", {"name" => "bash"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("yum")
  end
end
