require "../spec_helper"
require "../../src/krikri/plugin_helpers/rhsm_repository"

# Unit-tests the rhsm_repository planning logic against real
# community.general.rhsm_repository's own behavior (parsed from its
# list_repositories/repository_modify). The execution path needs a real
# registered RHEL system running subscription-manager, which no spec
# environment has - the output shapes and decision logic don't.
def sample_repos
  [
    Krikri::PluginHelpers::RhsmRepository::Repo.new("rhel-7-server-rpms", "Red Hat Enterprise Linux 7 Server (RPMs)", "https://cdn.redhat.com/...", true),
    Krikri::PluginHelpers::RhsmRepository::Repo.new("rhel-7-server-extras-rpms", "RHEL 7 Server Extras (RPMs)", "https://cdn.redhat.com/...", false),
    Krikri::PluginHelpers::RhsmRepository::Repo.new("rhel-7-server-optional-rpms", "RHEL 7 Server Optional (RPMs)", "https://cdn.redhat.com/...", true),
  ]
end

def sample_listing
  # Indentation mirrors real `subscription-manager repos --list` output:
  # header/banner lines are indented (the real module skips any line
  # starting with '+' or ' '), repo field lines are not.
  <<-OUTPUT
  +------------------------------------------+
      Available Repositories in /etc/sysconfig/rhsm/repos.conf
      ------------------------------------------
  Repo ID:   rhel-7-server-rpms
  Repo Name: Red Hat Enterprise Linux 7 Server (RPMs)
  Repo URL:  https://cdn.redhat.com/content/el7/x86_64/os
  Enabled:   1

  Repo ID:   rhel-7-server-extras-rpms
  Repo Name: RHEL 7 Server Extras (RPMs)
  Repo URL:  https://cdn.redhat.com/content/el7/extras/x86_64/os
  Enabled:   0

  Repo ID:   rhel-7-server-optional-rpms
  Repo Name: RHEL 7 Server Optional (RPMs)
  Repo URL:  https://cdn.redhat.com/content/el7/optional/x86_64/os
  Enabled:   1

  OUTPUT
end

describe Krikri::PluginHelpers::RhsmRepository do
  describe ".parse_list" do
    it "walks subscription-manager repos --list blocks" do
      repos = Krikri::PluginHelpers::RhsmRepository.parse_list(sample_listing)
      repos.size.should eq(3)
      repos[0].id.should eq("rhel-7-server-rpms")
      repos[0].enabled.should be_true
      repos[0].url.should eq("https://cdn.redhat.com/content/el7/x86_64/os")
      repos[1].id.should eq("rhel-7-server-extras-rpms")
      repos[1].enabled.should be_false
    end

    it "skips the header/banner lines" do
      repos = Krikri::PluginHelpers::RhsmRepository.parse_list("This system has no repositories available through subscriptions.\n")
      repos.size.should eq(0)
    end
  end

  describe ".glob_match?" do
    it "matches exact ids" do
      Krikri::PluginHelpers::RhsmRepository.glob_match?("rhel-7-server-rpms", "rhel-7-server-rpms").should be_true
    end

    it "matches trailing-* globs like the real fnmatch" do
      Krikri::PluginHelpers::RhsmRepository.glob_match?("rhel-6-server-extras-rpms", "rhel-6-server*").should be_true
      Krikri::PluginHelpers::RhsmRepository.glob_match?("rhel-7-server-rpms", "rhel-6-server*").should be_false
    end

    it "matches bare '*' against everything" do
      Krikri::PluginHelpers::RhsmRepository.glob_match?("anything", "*").should be_true
    end

    it "treats '?' as one character" do
      Krikri::PluginHelpers::RhsmRepository.glob_match?("rhel-8", "rhel-?").should be_true
      Krikri::PluginHelpers::RhsmRepository.glob_match?("rhel-88", "rhel-?").should be_false
    end
  end

  describe ".plan" do
    it "enables a disabled repo (state=enabled)" do
      plan = Krikri::PluginHelpers::RhsmRepository.plan(sample_repos, ["rhel-7-server-extras-rpms"], "enabled", false)
      plan.changed.should be_true
      plan.enable.should eq(["rhel-7-server-extras-rpms"])
      plan.disable.empty?.should be_true
    end

    it "is a no-op when the repo is already in the desired state" do
      plan = Krikri::PluginHelpers::RhsmRepository.plan(sample_repos, ["rhel-7-server-rpms"], "enabled", false)
      plan.changed.should be_false
      plan.enable.empty?.should be_true
    end

    it "disables an enabled repo (state=disabled)" do
      plan = Krikri::PluginHelpers::RhsmRepository.plan(sample_repos, ["rhel-7-server-rpms"], "disabled", false)
      plan.changed.should be_true
      plan.disable.should eq(["rhel-7-server-rpms"])
    end

    it "fails when a pattern matches no repo" do
      plan = Krikri::PluginHelpers::RhsmRepository.plan(sample_repos, ["not-a-repo"], "enabled", false)
      plan.invalid_pattern.should eq("not-a-repo")
      plan.changed.should be_false
    end

    it "purge disables enabled repos outside the requested list" do
      plan = Krikri::PluginHelpers::RhsmRepository.plan(sample_repos, ["rhel-7-server-rpms"], "enabled", true)
      plan.changed.should be_true
      plan.disable.should eq(["rhel-7-server-optional-rpms"])
      plan.enable.empty?.should be_true
      plan.updated.find { |r| r.id == "rhel-7-server-optional-rpms" }.not_nil!.enabled.should be_false
      plan.updated.find { |r| r.id == "rhel-7-server-rpms" }.not_nil!.enabled.should be_true
    end

    it "purge leaves already-disabled repos alone" do
      plan = Krikri::PluginHelpers::RhsmRepository.plan(sample_repos, ["rhel-7-server-rpms", "rhel-7-server-optional-rpms"], "enabled", true)
      plan.changed.should be_false
      plan.disable.should eq([] of String)
      plan.enable.should eq([] of String)
    end

    it "wildcard names enable everything under purge" do
      plan = Krikri::PluginHelpers::RhsmRepository.plan(sample_repos, ["*"], "enabled", true)
      plan.changed.should be_true
      plan.enable.should eq(["rhel-7-server-extras-rpms"])
      plan.updated.all?(&.enabled).should be_true
    end
  end
end
