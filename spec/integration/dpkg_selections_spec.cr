require "../spec_helper"

describe "dpkg_selections plugin" do
  it "fails with a clear message for an invalid selection" do
    result = PluginSpecHelper.run("dpkg_selections", {"name" => "bash", "selection" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("selection must be one of")
  end

  it "fails when name is missing" do
    result = PluginSpecHelper.run("dpkg_selections", {"selection" => "hold"})

    result["failed"].as_bool.should be_true
  end

  it "fails when selection is missing" do
    result = PluginSpecHelper.run("dpkg_selections", {"name" => "bash"})

    result["failed"].as_bool.should be_true
  end
end
