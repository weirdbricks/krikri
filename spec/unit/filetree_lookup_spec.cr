require "../spec_helper"
require "file_utils"
require "../../src/krikri/filetree_lookup"

# Regression: buluma.vector (round 300054) iterates its config skeleton
# with `with_community.general.filetree:` - the community.general.filetree
# lookup plugin had no native implementation at all, so the task key fell
# through unrecognized and `item` was never bound. These specs pin the
# real plugin's semantics (translated from
# community.general/plugins/lookup/filetree.py, not guessed) on a real
# temp tree.
private def ft_s(props : Hash(String, JSON::Any), key : String) : String
  props[key]?.try(&.as_s) || ""
end

describe Krikri::FiletreeLookup do
  describe ".resolve" do
    it "yields one entry per file and per subdirectory at every depth, directories before files" do
      root = File.tempname("filetree-root")
      Dir.mkdir_p(File.join(root, "subdir"))
      File.write(File.join(root, "top.conf"), "top")
      File.write(File.join(root, "subdir", "nested.conf"), "nested")

      entries = Krikri::FiletreeLookup.resolve([root], nil)

      # Sorted: "subdir" (directory) and "top.conf" (file) at depth 0,
      # then "subdir/nested.conf" at depth 1.
      entries.map { |e| ft_s(e, "path") }.should eq([
        "subdir", "top.conf", File.join("subdir", "nested.conf"),
      ])
      entries[0]["state"].as_s.should eq("directory")
      entries[1]["state"].as_s.should eq("file")
      entries[2]["state"].as_s.should eq("file")
    ensure
      FileUtils.rm_rf(root) if root
    end

    it "gives directory entries no src key at all (roles gate on item.state == 'file')" do
      root = File.tempname("filetree-root")
      Dir.mkdir_p(File.join(root, "subdir"))
      File.write(File.join(root, "top.conf"), "top")

      entries = Krikri::FiletreeLookup.resolve([root], nil)

      entries[0].has_key?("src").should be_false
      entries[1]["src"].as_s.should eq(File.join(root, "top.conf"))
    ensure
      FileUtils.rm_rf(root) if root
    end

    it "reports link state with the raw readlink target as src" do
      root = File.tempname("filetree-root")
      Dir.mkdir_p(root)
      File.write(File.join(root, "real.conf"), "real")
      File.symlink(File.join(root, "real.conf"), File.join(root, "link.conf"))

      entries = Krikri::FiletreeLookup.resolve([root], nil)
      link = entries.find { |e| ft_s(e, "path") == "link.conf" }.should_not be_nil

      link["state"].as_s.should eq("link")
      link["src"].as_s.should eq(File.join(root, "real.conf"))
    ensure
      FileUtils.rm_rf(root) if root
    end

    it "formats mode as a 4-char octal string" do
      root = File.tempname("filetree-root")
      Dir.mkdir_p(root)
      path = File.join(root, "script.sh")
      File.write(path, "x")
      File.chmod(path, 0o755)

      entries = Krikri::FiletreeLookup.resolve([root], nil)

      entries[0]["mode"].as_s.should eq("0755")
    ensure
      FileUtils.rm_rf(root) if root
    end

    it "resolves owner/group to names, falling back to the raw ids" do
      root = File.tempname("filetree-root")
      Dir.mkdir_p(root)
      File.write(File.join(root, "f"), "x")

      entries = Krikri::FiletreeLookup.resolve([root], nil)
      owner = entries[0]["owner"].as_s
      group = entries[0]["group"].as_s

      # Whatever the test env's passwd/group tables say, the entry must
      # be a nonempty name or the numeric id string - never "" and never
      # a raw uid INTEGER (real filetree's file_props only ever emits
      # strings for owner/group; the numeric uid/gid ride along under
      # their own keys).
      owner.should_not eq("")
      group.should_not eq("")
      entries[0]["uid"].raw.should be_a(Int64)
      entries[0]["gid"].raw.should be_a(Int64)
    ensure
      FileUtils.rm_rf(root) if root
    end

    it "dedupes a relative path already yielded by an earlier root (first-found across terms)" do
      root_a = File.tempname("filetree-a")
      root_b = File.tempname("filetree-b")
      Dir.mkdir_p(File.join(root_a, "common"))
      Dir.mkdir_p(File.join(root_b, "common"))
      File.write(File.join(root_a, "common", "a.conf"), "a")
      File.write(File.join(root_b, "common", "b.conf"), "b")

      entries = Krikri::FiletreeLookup.resolve([root_a, root_b], nil)

      # "common" itself and common/a.conf come from root_a; common/b.conf
      # (a relative path root_a never yielded) still comes from root_b.
      entries.map { |e| ft_s(e, "path") }.should eq([
        "common", File.join("common", "a.conf"), File.join("common", "b.conf"),
      ])
      entries[2]["root"].as_s.should eq(root_b)
    ensure
      FileUtils.rm_rf(root_a) if root_a
      FileUtils.rm_rf(root_b) if root_b
    end

    it "yields no entries for a missing root (os.walk of a nonexistent path is empty, never an error)" do
      entries = Krikri::FiletreeLookup.resolve(["/nonexistent/filetree-root-xyz"], nil)
      entries.should eq([] of Hash(String, JSON::Any))
    end

    it "dwims a relative source against the role's files/ directory" do
      role_path = File.tempname("filetree-role")
      Dir.mkdir_p(File.join(role_path, "files", "config"))
      File.write(File.join(role_path, "files", "config", "app.conf"), "app")

      entries = Krikri::FiletreeLookup.resolve(["config"], role_path)

      # Real filetree computes item.path RELATIVE TO THE WALKED ROOT
      # (os.path.relpath against the dwimmed term path) - so for the term
      # "config" resolved to <role>/files/config, the entry's path is
      # "app.conf", not "config/app.conf".
      entries.size.should eq(1)
      entries[0]["path"].as_s.should eq("app.conf")
    ensure
      FileUtils.rm_rf(role_path) if role_path
    end
  end
end
