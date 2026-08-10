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

  it "fails with a clear message for a line that isn't deb/deb-src or ppa:" do
    result = PluginSpecHelper.run("apt_repository", {"repo" => "not a valid repo line"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Invalid repo line")
  end

  # ppa: shorthand (see plugins/apt_repository.cr's own class doc for the
  # full formula breakdown - expands to a real deb line, fetches a
  # signing key from the real Launchpad API over HTTP, and exports it via
  # gpg). The two paths below never reach the network at all - matching
  # real Ansible's own behavior exactly (check_mode and an
  # already-satisfied state: absent both return before ever calling
  # _get_ppa_info) - so they're safe to exercise for real, unlike a
  # genuine PPA add/remove which would need real internet access and
  # write access to /etc/apt/. The actual network+GPG path was verified
  # by hand in a container instead - see git log.
  it "expands ppa: to the exact real-Ansible deb line shape and reports it would add (check mode, no network)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo" => "ppa:nginx/stable", "codename" => "jammy", "check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    result["repo"].as_s.should eq("deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main")
  end

  it "reports a ppa: repository already absent as a no-op (state: absent, no network)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo" => "ppa:nginx/stable", "codename" => "jammy", "state" => "absent",
    })

    result["changed"].as_bool.should be_false
    result["repo"].as_s.should eq("deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main")
  end
end
