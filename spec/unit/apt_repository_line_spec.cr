require "../spec_helper"
require "../../src/krikri/plugin_helpers/apt_repository_line"

# suggested_filename outputs below are cross-checked against a direct
# Python re-implementation of apt_repository.py's own `_suggest_filename`
# (read from the real ansible-core source, not assumed from docs) for the
# same inputs - see plugins/apt_repository.cr's module comment.
describe Krikri::PluginHelpers::AptRepositoryLine do
  describe ".normalize" do
    it "accepts a deb line and collapses whitespace" do
      Krikri::PluginHelpers::AptRepositoryLine.normalize("  deb   http://example.com/ubuntu   focal main  ")
        .should eq("deb http://example.com/ubuntu focal main")
    end

    it "accepts a deb-src line" do
      Krikri::PluginHelpers::AptRepositoryLine.normalize("deb-src http://example.com/ubuntu focal main")
        .should eq("deb-src http://example.com/ubuntu focal main")
    end

    it "returns nil for a line that doesn't start with deb/deb-src" do
      Krikri::PluginHelpers::AptRepositoryLine.normalize("ppa:someuser/someppa").should be_nil
    end

    it "returns nil for an empty line" do
      Krikri::PluginHelpers::AptRepositoryLine.normalize("   ").should be_nil
    end
  end

  describe ".suggested_filename" do
    it "derives a filename from the host and path" do
      Krikri::PluginHelpers::AptRepositoryLine.suggested_filename("deb http://archive.ubuntu.com/ubuntu focal main")
        .should eq("archive_ubuntu_com_ubuntu")
    end

    it "treats deb-src the same as deb" do
      Krikri::PluginHelpers::AptRepositoryLine.suggested_filename("deb-src http://archive.ubuntu.com/ubuntu focal main")
        .should eq("archive_ubuntu_com_ubuntu")
    end

    it "strips [options] before deriving the filename" do
      Krikri::PluginHelpers::AptRepositoryLine.suggested_filename("deb [arch=amd64] http://mirror.example.com/repo stable main")
        .should eq("mirror_example_com_repo")
    end

    it "strips a user:pass@ prefix from the host" do
      Krikri::PluginHelpers::AptRepositoryLine.suggested_filename("deb http://user:pass@mirror.example.com/repo stable main")
        .should eq("mirror_example_com_repo")
    end
  end
end
