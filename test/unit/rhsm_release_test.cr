require "../minitest_helper"
require "../../src/krikri/plugin_helpers/rhsm_release"

# Unit-tests the rhsm_release logic against real community.general
# .rhsm_release's own behavior (release_matcher lifted verbatim from the
# module source). The execution path needs a real registered RHEL host,
# which no spec environment has - the regex/argv shapes don't.
describe Krikri::PluginHelpers::RhsmRelease do
  describe ".current_release" do
    it "extracts the first release-like token from release --show output" do
      Krikri::PluginHelpers::RhsmRelease.current_release("Release: 8.4").must_equal("8.4")
    end

    it "handles word-style releases like 6Server" do
      Krikri::PluginHelpers::RhsmRelease.current_release("Release: 6Server").must_equal("6Server")
    end

    it "returns nil when the release is unset" do
      Krikri::PluginHelpers::RhsmRelease.current_release("Release not set").must_be_nil
    end

    it "rejects unlikely values like the real matcher" do
      Krikri::PluginHelpers::RhsmRelease.current_release("Release: 100Server").must_be_nil
      Krikri::PluginHelpers::RhsmRelease.current_release("Release: 7server").must_be_nil
    end
  end

  describe ".valid_release?" do
    it "accepts dotted minors, plain majors and word releases" do
      ["7.1", "5.10", "8", "6Server", "7Client", "7Workstation"].each do |release|
        Krikri::PluginHelpers::RhsmRelease.valid_release?(release).must_equal(true)
      end
    end

    it "rejects values the real module's sanity check rejects" do
      ["100Server", "7server", "banana"].each do |release|
        Krikri::PluginHelpers::RhsmRelease.valid_release?(release).must_equal(false)
      end
    end
  end

  describe ".release_arguments" do
    it "builds --set with the release" do
      Krikri::PluginHelpers::RhsmRelease.release_arguments("8.4").must_equal("release --set 8.4")
    end

    it "builds --unset when the release is nil" do
      Krikri::PluginHelpers::RhsmRelease.release_arguments(nil).must_equal("release --unset")
    end

    it "single-quotes a hostile release so it stays one literal argument" do
      # valid_release?'s matcher is a non-anchored substring match, so a
      # value like this PASSES validation and reaches the command string.
      Krikri::PluginHelpers::RhsmRelease.release_arguments("7.2; touch /tmp/pwned")
        .must_equal("release --set '7.2; touch /tmp/pwned'")
    end
  end
end
