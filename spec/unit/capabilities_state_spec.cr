require "../spec_helper"
require "file_utils"

# Pins plugins/capabilities.cr's state validation against real
# community.general.capabilities: the module's argument spec limits
# state to [absent, present] (default present), and AnsibleModule fails
# any other value before setcap ever runs. Confirmed against real
# ansible-playbook via testing/podman-diff/cases/capabilities_edge_cases.yml
# case E10.
describe "capabilities plugin state validation" do
  it "fails on a state outside the argument-spec choices" do
    bin = File.join(Dir.tempdir, "krikri-cap-spec-#{Random::Secure.hex(6)}")
    FileUtils.cp("/bin/sleep", bin)
    begin
      result = PluginSpecHelper.run("capabilities", {
        "path"       => bin,
        "capability" => "cap_net_raw+ep",
        "state"      => "banana",
      })

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_false
    ensure
      File.delete?(bin)
    end
  end

  it "accepts the valid states without a validation failure" do
    bin = File.join(Dir.tempdir, "krikri-cap-spec-#{Random::Secure.hex(6)}")
    FileUtils.cp("/bin/sleep", bin)
    begin
      result = PluginSpecHelper.run("capabilities", {
        "path"       => bin,
        "capability" => "cap_net_raw+ep",
        "state"      => "absent",
      })

      result["failed"]?.nil?.should be_true
    ensure
      File.delete?(bin)
    end
  end
end
