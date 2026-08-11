require "../spec_helper"

# deb822_repository writes to /etc/apt/sources.list.d/, which needs
# root - these specs exercise check_mode / param-rendering only (no
# real file write needed to observe the rendered content), matching
# the same convention spec/integration/apt_repository_spec.cr already
# uses for root-only plugins.
describe "deb822_repository plugin" do
  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("deb822_repository", {
      "uris"   => "https://example.com/repo",
      "suites" => "stable",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("name")
  end

  it "fails with a clear message when uris is missing" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"   => "testrepo",
      "suites" => "stable",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("uris")
  end

  it "reports it would add a repository that isn't present yet (check mode, no real change)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "totally-fake-example-repo",
      "types"      => "deb",
      "uris"       => "https://packages.totally-fake-example.com/repo",
      "suites"     => "stable",
      "components" => "main",
      "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
  end

  it "reports it would remove a repository when state: absent and it isn't present (no-op either way, safe even without check mode)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"  => "totally-fake-example-repo-that-does-not-exist",
      "state" => "absent",
    })

    result["changed"].as_bool.should be_false
  end
end
