require "../spec_helper"

describe "subversion plugin" do
  it "fails when repo is missing" do
    result = PluginSpecHelper.run("subversion", {"dest" => "/tmp/svn-checkout-test"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("repo")
  end

  it "fails when dest is missing" do
    result = PluginSpecHelper.run("subversion", {"repo" => "https://example.com/svn/repo"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("dest")
  end
end
