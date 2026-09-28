require "../minitest_helper"

describe "subversion plugin" do
  it "fails when repo is missing" do
    result = PluginSpecHelper.run("subversion", {"dest" => PluginSpecHelper.tmp_path("svn-checkout-test")})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("repo")
  end

  it "fails when dest is missing" do
    result = PluginSpecHelper.run("subversion", {"repo" => "https://example.com/svn/repo"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("dest")
  end
end
