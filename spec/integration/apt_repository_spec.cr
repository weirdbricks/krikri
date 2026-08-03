require "../spec_helper"

# apt_repository writes to /etc/apt/sources.list.d/, which needs root -
# these specs exercise check_mode only (read-only, safe on a real
# machine), matching the same convention spec/integration/user_spec.cr
# and group_spec.cr already use for root-only plugins.
describe "apt_repository plugin" do
  it "reports it would add a repository that isn't present yet (check mode, no real change)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"       => "deb https://packages.totally-fake-example.com/repo stable main",
      "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    result["state"].as_s.should eq("present")
  end

  it "normalizes whitespace before checking/reporting the repo line" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"       => "  deb   https://packages.totally-fake-example.com/repo   stable main  ",
      "check_mode" => "true",
    })

    result["repo"].as_s.should eq("deb https://packages.totally-fake-example.com/repo stable main")
  end

  it "reports it would remove a repository when state: absent and it isn't present (no-op either way, safe even without check mode)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"  => "deb https://packages.totally-fake-example.com/repo stable main",
      "state" => "absent",
    })

    result["changed"].as_bool.should be_false
    result["state"].as_s.should eq("absent")
  end

  it "fails with a clear message when repo is missing" do
    result = PluginSpecHelper.run("apt_repository", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("repo")
  end

  it "fails with a clear message for a line that isn't a deb/deb-src source" do
    result = PluginSpecHelper.run("apt_repository", {"repo" => "ppa:someuser/someppa"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Invalid repo line")
  end
end
