require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/file_attributes"

describe CrystalPlay::PluginHelpers::FileAttributes do
  describe ".parse_mime" do
    it "parses a real `file --mime-type --mime-encoding` line" do
      mimetype, charset = CrystalPlay::PluginHelpers::FileAttributes.parse_mime("/etc/hostname: text/plain; charset=us-ascii")
      mimetype.should eq("text/plain")
      charset.should eq("us-ascii")
    end

    it "tolerates a colon inside the path itself, using the last colon as the separator" do
      mimetype, charset = CrystalPlay::PluginHelpers::FileAttributes.parse_mime("/weird:path: application/pdf; charset=binary")
      mimetype.should eq("application/pdf")
      charset.should eq("binary")
    end

    it "falls back to unknown/unknown (real Ansible's own fallback) on unparseable output" do
      mimetype, charset = CrystalPlay::PluginHelpers::FileAttributes.parse_mime("")
      mimetype.should eq("unknown")
      charset.should eq("unknown")
    end
  end

  describe ".parse_lsattr" do
    it "parses a real `lsattr -vd` line with a version and one flag set" do
      version, attr_flags, attributes = CrystalPlay::PluginHelpers::FileAttributes.parse_lsattr("719511458  --------------e------- /etc/hostname")
      version.should eq("719511458")
      attr_flags.should eq("e")
      attributes.should eq(["extents"])
    end

    it "returns empty attr_flags/attributes when no flags are set" do
      version, attr_flags, attributes = CrystalPlay::PluginHelpers::FileAttributes.parse_lsattr("12345  ---------------------- /tmp/x")
      version.should eq("12345")
      attr_flags.should eq("")
      attributes.should eq([] of String)
    end

    it "maps multiple flags to their real Ansible attribute names" do
      _, attr_flags, attributes = CrystalPlay::PluginHelpers::FileAttributes.parse_lsattr("1  ----i---------e------- /x")
      attr_flags.should eq("ie")
      attributes.should eq(["immutable", "extents"])
    end

    it "falls back to nil/empty/[] (real Ansible's own fallback) on unparseable output" do
      version, attr_flags, attributes = CrystalPlay::PluginHelpers::FileAttributes.parse_lsattr("")
      version.should be_nil
      attr_flags.should eq("")
      attributes.should eq([] of String)
    end
  end
end
