require "../minitest_helper"
require "../../src/krikri/plugin_helpers/file_attributes"

describe Krikri::PluginHelpers::FileAttributes do
  describe ".parse_mime" do
    it "parses a real `file --mime-type --mime-encoding` line" do
      mimetype, charset = Krikri::PluginHelpers::FileAttributes.parse_mime("/etc/hostname: text/plain; charset=us-ascii")
      mimetype.must_equal("text/plain")
      charset.must_equal("us-ascii")
    end

    it "tolerates a colon inside the path itself, using the last colon as the separator" do
      mimetype, charset = Krikri::PluginHelpers::FileAttributes.parse_mime("/weird:path: application/pdf; charset=binary")
      mimetype.must_equal("application/pdf")
      charset.must_equal("binary")
    end

    it "falls back to unknown/unknown (real Ansible's own fallback) on unparseable output" do
      mimetype, charset = Krikri::PluginHelpers::FileAttributes.parse_mime("")
      mimetype.must_equal("unknown")
      charset.must_equal("unknown")
    end
  end

  describe ".parse_lsattr" do
    it "parses a real `lsattr -vd` line with a version and one flag set" do
      version, attr_flags, attributes = Krikri::PluginHelpers::FileAttributes.parse_lsattr("719511458  --------------e------- /etc/hostname")
      version.must_equal("719511458")
      attr_flags.must_equal("e")
      attributes.must_equal(["extents"])
    end

    it "returns empty attr_flags/attributes when no flags are set" do
      version, attr_flags, attributes = Krikri::PluginHelpers::FileAttributes.parse_lsattr("12345  ---------------------- /tmp/x")
      version.must_equal("12345")
      attr_flags.must_equal("")
      attributes.must_equal([] of String)
    end

    it "maps multiple flags to their real Ansible attribute names" do
      _, attr_flags, attributes = Krikri::PluginHelpers::FileAttributes.parse_lsattr("1  ----i---------e------- /x")
      attr_flags.must_equal("ie")
      attributes.must_equal(["immutable", "extents"])
    end

    it "falls back to nil/empty/[] (real Ansible's own fallback) on unparseable output" do
      version, attr_flags, attributes = Krikri::PluginHelpers::FileAttributes.parse_lsattr("")
      version.must_be_nil
      attr_flags.must_equal("")
      attributes.must_equal([] of String)
    end
  end
end
