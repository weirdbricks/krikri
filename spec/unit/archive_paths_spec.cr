require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/archive_paths"

# arcroot values below are verified against real ansible-playbook's actual
# output for the equivalent path sets (community.general 11.2.1 /
# ansible-core 2.19), not derived from documentation - this is where a
# real bug was caught: Crystal's File.dirname on a trailing-slash path
# returns the level ABOVE it, unlike Python's os.path.dirname, which just
# strips the trailing slash.
describe CrystalPlay::PluginHelpers::ArchivePaths do
  describe ".common_path" do
    it "uses the parent directory as root for a single directory path" do
      CrystalPlay::PluginHelpers::ArchivePaths.common_path(["/tmp/archtest/src"]).should eq("/tmp/archtest/")
    end

    it "uses the file's own directory as root for a single file path" do
      CrystalPlay::PluginHelpers::ArchivePaths.common_path(["/tmp/archtest/src/a.txt"]).should eq("/tmp/archtest/src/")
    end

    it "uses the shared parent directory as root for multiple files in the same directory" do
      paths = ["/tmp/archtest/src/a.txt", "/tmp/archtest/src/b.txt"]
      CrystalPlay::PluginHelpers::ArchivePaths.common_path(paths).should eq("/tmp/archtest/src/")
    end
  end

  describe ".python_dirname" do
    it "strips only the trailing slash from a path already ending in one" do
      CrystalPlay::PluginHelpers::ArchivePaths.python_dirname("/tmp/archtest/src/").should eq("/tmp/archtest/src")
    end

    it "removes the last path component from a path with no trailing slash" do
      CrystalPlay::PluginHelpers::ArchivePaths.python_dirname("/tmp/archtest/src").should eq("/tmp/archtest")
    end

    it "returns '/' for a top-level path" do
      CrystalPlay::PluginHelpers::ArchivePaths.python_dirname("/tmp").should eq("/")
    end
  end

  describe ".string_common_prefix" do
    it "returns the shared leading substring of a list of strings" do
      CrystalPlay::PluginHelpers::ArchivePaths.string_common_prefix(["/a/b/", "/a/c/"]).should eq("/a/")
    end

    it "returns the whole string for a single-element list" do
      CrystalPlay::PluginHelpers::ArchivePaths.string_common_prefix(["/a/b/"]).should eq("/a/b/")
    end

    it "returns an empty string for an empty list" do
      CrystalPlay::PluginHelpers::ArchivePaths.string_common_prefix([] of String).should eq("")
    end
  end
end
