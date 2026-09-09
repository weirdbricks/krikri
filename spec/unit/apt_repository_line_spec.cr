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

  describe ".target_sources_path" do
    sources_list_d = "/etc/apt/sources.list.d"
    repo_line = "deb https://download.keydb.dev/open-source-dist jammy main"

    # Regression: v0112358.keydb_active_replication passes
    # `filename: /etc/apt/sources.list.d/keydb.list` - a FULL path.
    # Real Ansible's `_suggest_filename` returns the param verbatim,
    # unconditionally appends `.list` (so `.list.list` - a genuine,
    # verified quirk of its own source), and `_expand_path` passes any
    # candidate containing '/' through as-is instead of joining
    # sources.list.d. The repo file apt actually reads is therefore
    # /etc/apt/sources.list.d/keydb.list.list (apt consumes ANY *.list
    # under sources.list.d). Krikri previously joined the full path
    # under sources.list.d instead, producing a nested
    # /etc/apt/sources.list.d//etc/apt/sources.list.d/keydb.list.list
    # apt never reads: `apt-get update` exited 0 with no GPG warning
    # (the repo was simply invisible), the task still reported
    # changed/success, and the later `apt: name=keydb` failed with
    # "Unable to locate package keydb" where real Ansible's identical
    # sequence installed it.
    it "honors a full-path filename: param verbatim (plus real Ansible's own .list suffix quirk)" do
      Krikri::PluginHelpers::AptRepositoryLine.target_sources_path(
        "/etc/apt/sources.list.d/keydb.list", repo_line, sources_list_d
      ).should eq("/etc/apt/sources.list.d/keydb.list.list")
    end

    it "joins a bare filename: param into sources.list.d with .list appended" do
      Krikri::PluginHelpers::AptRepositoryLine.target_sources_path(
        "keydb", repo_line, sources_list_d
      ).should eq("/etc/apt/sources.list.d/keydb.list")
    end

    it "derives the filename from the repo line when no filename: param is given" do
      Krikri::PluginHelpers::AptRepositoryLine.target_sources_path(
        nil, repo_line, sources_list_d
      ).should eq("/etc/apt/sources.list.d/download_keydb_dev_open_source_dist.list")
    end
  end
end
