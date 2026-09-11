require "../spec_helper"
require "../../src/krikri/plugin_helpers/rhsm_release"

# Unit-tests the rhsm_release logic against real community.general
# .rhsm_release's own behavior (release_matcher lifted verbatim from the
# module source). The execution path needs a real registered RHEL host,
# which no spec environment has - the regex/argv shapes don't.
describe Krikri::PluginHelpers::RhsmRelease do
  describe ".current_release" do
    it "extracts the first release-like token from release --show output" do
      Krikri::PluginHelpers::RhsmRelease.current_release("Release: 8.4").should eq("8.4")
    end

    it "handles word-style releases like 6Server" do
      Krikri::PluginHelpers::RhsmRelease.current_release("Release: 6Server").should eq("6Server")
    end

    it "returns nil when the release is unset" do
      Krikri::PluginHelpers::RhsmRelease.current_release("Release not set").should be_nil
    end

    it "rejects unlikely values like the real matcher" do
      Krikri::PluginHelpers::RhsmRelease.current_release("Release: 100Server").should be_nil
      Krikri::PluginHelpers::RhsmRelease.current_release("Release: 7server").should be_nil
    end
  end

  describe ".valid_release?" do
    it "accepts dotted minors, plain majors and word releases" do
      ["7.1", "5.10", "8", "6Server", "7Client", "7Workstation"].each do |release|
        Krikri::PluginHelpers::RhsmRelease.valid_release?(release).should be_true
      end
    end

    it "rejects values the real module's sanity check rejects" do
      ["100Server", "7server", "banana"].each do |release|
        Krikri::PluginHelpers::RhsmRelease.valid_release?(release).should be_false
      end
    end
  end

  describe ".set_arguments" do
    it "builds --set with the release" do
      Krikri::PluginHelpers::RhsmRelease.set_arguments("8.4").should eq("release --set 8.4")
    end

    it "builds --unset when the release is nil" do
      Krikri::PluginHelpers::RhsmRelease.set_arguments(nil).should eq("release --unset")
    end
  end
end
