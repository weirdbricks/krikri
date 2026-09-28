require "../minitest_helper"
require "../../src/krikri/plugin_helpers/find_mode_filter"

# Real bug found via a proactive scope-cut audit: find:'s mode:/
# exact_mode: were entirely unimplemented. Verified against real
# ansible/modules/find.py's own mode_filter source directly.
describe Krikri::PluginHelpers::FindModeFilter do
  describe ".parse_mode" do
    it "parses an octal string" do
      Krikri::PluginHelpers::FindModeFilter.parse_mode("0644").must_equal(0o644)
      Krikri::PluginHelpers::FindModeFilter.parse_mode("644").must_equal(0o644)
    end

    it "parses a symbolic u=,g=,o= assignment (ansible-doc's own example shape)" do
      Krikri::PluginHelpers::FindModeFilter.parse_mode("u=rw,g=r,o=r").must_equal(0o644)
    end

    it "parses a= as shorthand for all three targets" do
      Krikri::PluginHelpers::FindModeFilter.parse_mode("a=r").must_equal(0o444)
    end

    it "parses a bare = (empty target list) the same as a=" do
      Krikri::PluginHelpers::FindModeFilter.parse_mode("=rwx").must_equal(0o777)
    end

    it "leaves unspecified targets at 0" do
      Krikri::PluginHelpers::FindModeFilter.parse_mode("u=rwx").must_equal(0o700)
    end

    it "returns nil for an unsupported symbolic grammar (+/- operators)" do
      Krikri::PluginHelpers::FindModeFilter.parse_mode("u+x").must_be_nil
    end
  end

  describe ".matches?" do
    it "exact_mode: true requires an identical mode" do
      Krikri::PluginHelpers::FindModeFilter.matches?(0o644, "0644", true).must_equal(true)
      Krikri::PluginHelpers::FindModeFilter.matches?(0o755, "0644", true).must_equal(false)
    end

    it "exact_mode: false matches if ANY requested bit is present (real Ansible's own bitwise-AND semantics, not a full-superset check)" do
      # 0o600 (rw-------) & 0o644 (rw-r--r--) = 0o600, nonzero -> true,
      # even though 0o600 doesn't have every bit 0o644 asks for.
      Krikri::PluginHelpers::FindModeFilter.matches?(0o600, "0644", false).must_equal(true)
      # 0o100 (--x------) & 0o044 (---r--r--) = 0, no overlap -> false.
      Krikri::PluginHelpers::FindModeFilter.matches?(0o100, "044", false).must_equal(false)
    end

    it "returns false for an unparseable mode string rather than raising" do
      Krikri::PluginHelpers::FindModeFilter.matches?(0o644, "u+x", true).must_equal(false)
    end
  end
end
