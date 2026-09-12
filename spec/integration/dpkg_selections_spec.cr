require "../spec_helper"

# Message texts live-verified against real ansible-core's
# dpkg_selections.py argument_spec:
#   "value of selection must be one of: install, hold, deinstall, purge,
#    got: bogus" (choices in the argument_spec's declaration order)
#   "missing required arguments: selection" (plural, even for one param)
describe "dpkg_selections plugin" do
  it "fails with real-Ansible wording for an invalid selection" do
    result = PluginSpecHelper.run("dpkg_selections", {"name" => "bash", "selection" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of selection must be one of: install, hold, deinstall, purge, got: bogus")
  end

  it "fails with plural 'missing required arguments' when name is missing" do
    result = PluginSpecHelper.run("dpkg_selections", {"selection" => "hold"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "fails with plural 'missing required arguments' when selection is missing" do
    result = PluginSpecHelper.run("dpkg_selections", {"name" => "bash"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: selection")
  end
end
