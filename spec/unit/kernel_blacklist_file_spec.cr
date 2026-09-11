require "../spec_helper"
require "../../src/krikri/plugin_helpers/kernel_blacklist_file"

# Unit-tests the line-editing logic against real
# community.general.kernel_blacklist's own semantics (read from its
# source): the `^blacklist\s+<name>$` pattern over stripped
# non-comment lines, and file-creation counting as a change.
describe Krikri::PluginHelpers::KernelBlacklistFile do
  describe ".blacklisted?" do
    it "matches an exact blacklist entry" do
      lines = ["# comment", "blacklist nouveau"]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").should be_true
    end

    it "matches with arbitrary whitespace and surrounding padding" do
      lines = ["  blacklist   nouveau  "]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").should be_true
    end

    it "does not match comment lines mentioning the module" do
      lines = ["# blacklist nouveau was here"]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").should be_false
    end

    it "does not match a partial module name" do
      lines = ["blacklist nouveau_drm"]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").should be_false
    end

    it "does not match the module as a different entry type (install/alias)" do
      lines = ["alias nouveau off"]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").should be_false
    end
  end

  describe ".apply" do
    it "appends the entry for state=present when missing" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(["# x"], "nouveau", "present")
      changed.should be_true
      lines.should eq(["# x", "blacklist nouveau"])
    end

    it "is a no-op for state=present when already blacklisted" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(["blacklist nouveau"], "nouveau", "present")
      changed.should be_false
      lines.should eq(["blacklist nouveau"])
    end

    it "removes the entry for state=absent" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(
        ["# keep", "blacklist nouveau", "blacklist nvidia"], "nouveau", "absent"
      )
      changed.should be_true
      lines.should eq(["# keep", "blacklist nvidia"])
    end

    it "is a no-op for state=absent when not blacklisted" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(["# keep"], "nouveau", "absent")
      changed.should be_false
      lines.should eq(["# keep"])
    end

    it "counts creating a missing file as a change (real module quirk)" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(nil, "nouveau", "present")
      changed.should be_true
      lines.should eq(["blacklist nouveau"])

      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(nil, "nouveau", "absent")
      changed.should be_true
      lines.should be_empty
    end

    it "escapes regex metacharacters in the module name" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(["blacklist nouveau$"], "nouveau$", "present")
      changed.should be_false
      lines.should eq(["blacklist nouveau$"])
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(["blacklist nouveau$"], "nouveau$").should be_true
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(["blacklist nouveau$"], "nouveau").should be_false
    end
  end
end
