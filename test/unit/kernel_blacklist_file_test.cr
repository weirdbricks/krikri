require "../minitest_helper"
require "../../src/krikri/plugin_helpers/kernel_blacklist_file"

# Unit-tests the line-editing logic against real
# community.general.kernel_blacklist's own semantics (read from its
# source): the `^blacklist\s+<name>$` pattern over stripped
# non-comment lines, and file-creation counting as a change.
describe Krikri::PluginHelpers::KernelBlacklistFile do
  describe ".blacklisted?" do
    it "matches an exact blacklist entry" do
      lines = ["# comment", "blacklist nouveau"]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").must_equal(true)
    end

    it "matches with arbitrary whitespace and surrounding padding" do
      lines = ["  blacklist   nouveau  "]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").must_equal(true)
    end

    it "does not match comment lines mentioning the module" do
      lines = ["# blacklist nouveau was here"]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").must_equal(false)
    end

    it "does not match a partial module name" do
      lines = ["blacklist nouveau_drm"]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").must_equal(false)
    end

    it "does not match the module as a different entry type (install/alias)" do
      lines = ["alias nouveau off"]
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(lines, "nouveau").must_equal(false)
    end
  end

  describe ".apply" do
    it "appends the entry for state=present when missing" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(["# x"], "nouveau", "present")
      changed.must_equal(true)
      lines.must_equal(["# x", "blacklist nouveau"])
    end

    it "is a no-op for state=present when already blacklisted" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(["blacklist nouveau"], "nouveau", "present")
      changed.must_equal(false)
      lines.must_equal(["blacklist nouveau"])
    end

    it "removes the entry for state=absent" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(
        ["# keep", "blacklist nouveau", "blacklist nvidia"], "nouveau", "absent"
      )
      changed.must_equal(true)
      lines.must_equal(["# keep", "blacklist nvidia"])
    end

    it "is a no-op for state=absent when not blacklisted" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(["# keep"], "nouveau", "absent")
      changed.must_equal(false)
      lines.must_equal(["# keep"])
    end

    it "counts creating a missing file as a change (Ansible module quirk)" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(nil, "nouveau", "present")
      changed.must_equal(true)
      lines.must_equal(["blacklist nouveau"])

      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(nil, "nouveau", "absent")
      changed.must_equal(true)
      lines.must_be_empty
    end

    it "escapes regex metacharacters in the module name" do
      lines, changed = Krikri::PluginHelpers::KernelBlacklistFile.apply(["blacklist nouveau$"], "nouveau$", "present")
      changed.must_equal(false)
      lines.must_equal(["blacklist nouveau$"])
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(["blacklist nouveau$"], "nouveau$").must_equal(true)
      Krikri::PluginHelpers::KernelBlacklistFile.blacklisted?(["blacklist nouveau$"], "nouveau").must_equal(false)
    end
  end
end
