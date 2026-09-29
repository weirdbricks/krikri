require "../minitest_helper"
require "file_utils"

describe "archive plugin" do
  # Fixture tree lives in a per-test "archive" subtree under tmp_path.
  private def fixture_base : String
    PluginSpecHelper.tmp_path("archive")
  end

  before_each do
    base = fixture_base
    FileUtils.mkdir_p(File.join(base, "src", "sub"))
    File.write(File.join(base, "src", "a.txt"), "hello")
    File.write(File.join(base, "src", "b.txt"), "world")
    File.write(File.join(base, "src", "sub", "c.txt"), "nested")

    # A symlink pointing at a directory (e.g. Debian's default /var/spool/
    # mail -> ../mail) - regression fixture for build_tar/build_zip's own
    # symlink handling.
    FileUtils.mkdir_p(File.join(base, "symlink_src", "real_dir"))
    File.write(File.join(base, "symlink_src", "real_dir", "f.txt"), "hi")
    File.symlink("real_dir", File.join(base, "symlink_src", "link_dir"))
  end

  private def dest_path(name : String) : String
    PluginSpecHelper.tmp_path(name)
  end

  it "compresses a single file directly (not wrapped in a tar) with the default gz format" do
    dest = dest_path("single.gz")
    result = PluginSpecHelper.run("archive", {"path" => File.join(fixture_base, "src", "a.txt"), "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    result["dest_state"].as_s.must_equal("compress")
    `gzip -dc #{dest}`.must_equal("hello")
  end

  it "builds a real tar.gz for a directory, with correct arcroot, no duplicated members, and no entry for the requested directory itself (only its descendants - matches real Ansible's os.walk-based add_targets, verified against its actual source)" do
    dest = dest_path("dir.tar.gz")
    result = PluginSpecHelper.run("archive", {"path" => File.join(fixture_base, "src"), "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    result["dest_state"].as_s.must_equal("archive")
    result["arcroot"].as_s.must_equal(fixture_base + "/")

    listing = `tar tzf #{dest}`.lines.reject(&.empty?)
    listing.sort.must_equal(["src/a.txt", "src/b.txt", "src/sub/", "src/sub/c.txt"].sort)
  end

  it "reports changed: false on an idempotent rerun with unchanged content" do
    dest = dest_path("idempotent.tar.gz")
    PluginSpecHelper.run("archive", {"path" => File.join(fixture_base, "src"), "dest" => dest})

    result = PluginSpecHelper.run("archive", {"path" => File.join(fixture_base, "src"), "dest" => dest})

    result["changed"].as_bool.must_equal(false)
  end

  it "archives a directory containing a symlink to another directory, instead of crashing the whole build (tar)" do
    # Regression: File.open(member) on a symlink follows it - for one
    # pointing at a directory, that raises, and the single top-level
    # `rescue => false` around the whole build turned one bad member
    # into a total archive failure. Found benchmarking robertdebock.
    # backup's own default /var/spool target (Debian's own /var/spool/
    # mail -> ../mail).
    dest = dest_path("symlink.tar.gz")
    result = PluginSpecHelper.run("archive", {"path" => File.join(fixture_base, "symlink_src"), "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    listing = `tar tzf #{dest}`.lines.reject(&.empty?)
    listing.must_include("symlink_src/link_dir")
    `tar xzOf #{dest} symlink_src/real_dir/f.txt`.must_equal("hi")
  end

  it "archives a directory containing a symlink to another directory, instead of crashing the whole build (zip)" do
    dest = dest_path("symlink.zip")
    result = PluginSpecHelper.run("archive", {"path" => File.join(fixture_base, "symlink_src"), "dest" => dest, "format" => "zip"})

    result["changed"].as_bool.must_equal(true)
    `unzip -p #{dest} symlink_src/real_dir/f.txt`.must_equal("hi")
  end

  it "reports changed: true when source content changes since the last archive" do
    source_dir = PluginSpecHelper.tmp_path("idempotent_change_src")
    FileUtils.mkdir_p(source_dir)
    File.write(File.join(source_dir, "f.txt"), "v1")
    dest = dest_path("changed.tar.gz")
    PluginSpecHelper.run("archive", {"path" => source_dir, "dest" => dest})

    File.write(File.join(source_dir, "f.txt"), "v2")
    result = PluginSpecHelper.run("archive", {"path" => source_dir, "dest" => dest})

    result["changed"].as_bool.must_equal(true)
  end

  it "excludes matching basenames via exclusion_patterns, in both the tar contents and the reported archived list" do
    exc_dir = PluginSpecHelper.tmp_path("exctest")
    FileUtils.mkdir_p(exc_dir)
    File.write(File.join(exc_dir, "keep.txt"), "a")
    File.write(File.join(exc_dir, "skip.txt"), "b")
    dest = dest_path("exc.tar.gz")

    result = PluginSpecHelper.run("archive", {"path" => exc_dir, "dest" => dest, "exclusion_patterns" => "*skip*"})

    listing = `tar tzf #{dest}`
    listing.wont_include("skip.txt")
    listing.must_include("keep.txt")
    falsey?(result["archived"].as_a.map(&.as_s).any?(&.includes?("skip.txt"))).must_equal(true)
  end

  it "builds a real zip archive that honors exclusion_patterns too" do
    exc_dir = PluginSpecHelper.tmp_path("ziptest")
    FileUtils.mkdir_p(exc_dir)
    File.write(File.join(exc_dir, "keep.txt"), "a")
    File.write(File.join(exc_dir, "skip.txt"), "b")
    dest = dest_path("exc.zip")

    PluginSpecHelper.run("archive", {"path" => exc_dir, "dest" => dest, "format" => "zip", "exclusion_patterns" => "*skip*"})

    listing = `unzip -l #{dest}`
    listing.wont_include("skip.txt")
    listing.must_include("keep.txt")
  end

  it "does NOT exclude a nested file via exclude_path (real Ansible's own narrow behavior: only top-level path: entries are exact-matched)" do
    exc_dir = PluginSpecHelper.tmp_path("exclude_path_nested")
    FileUtils.mkdir_p(exc_dir)
    File.write(File.join(exc_dir, "keep.txt"), "a")
    File.write(File.join(exc_dir, "skip.txt"), "b")
    dest = dest_path("exclude-path-nested.tar.gz")

    result = PluginSpecHelper.run("archive", {"path" => exc_dir, "dest" => dest, "exclude_path" => File.join(exc_dir, "skip.txt")})

    listing = `tar tzf #{dest}`
    listing.must_include("skip.txt")
    listing.must_include("keep.txt")
    truthy?(result["archived"].as_a.map(&.as_s).any?(&.includes?("skip.txt"))).must_equal(true)
  end

  it "excludes an entry that exactly matches one of several top-level path: items" do
    top1 = PluginSpecHelper.tmp_path("exclude_path_top1.txt")
    top2 = PluginSpecHelper.tmp_path("exclude_path_top2.txt")
    File.write(top1, "one")
    File.write(top2, "two")
    dest = dest_path("exclude-path-top.tar.gz")

    result = PluginSpecHelper.run("archive", {
      "path" => "#{top1},#{top2}", "dest" => dest, "exclude_path" => top2, "force_archive" => "true",
    })

    listing = `tar tzf #{dest}`
    listing.wont_include("exclude_path_top2.txt")
    listing.must_include("exclude_path_top1.txt")
    falsey?(result["archived"].as_a.map(&.as_s).any?(&.includes?("exclude_path_top2.txt"))).must_equal(true)
  end

  it "still reports the full, unfiltered list in expanded_paths even when exclude_path removes one" do
    top1 = PluginSpecHelper.tmp_path("exclude_path_expanded1.txt")
    top2 = PluginSpecHelper.tmp_path("exclude_path_expanded2.txt")
    File.write(top1, "one")
    File.write(top2, "two")
    dest = dest_path("exclude-path-expanded.tar.gz")

    result = PluginSpecHelper.run("archive", {
      "path" => "#{top1},#{top2}", "dest" => dest, "exclude_path" => top2, "force_archive" => "true",
    })

    result["expanded_paths"].as_a.map(&.as_s).must_include(top2)
  end

  it "reports dest_state: incomplete and lists the missing path when one of several paths doesn't exist" do
    dest = dest_path("partial.tar.gz")
    result = PluginSpecHelper.run("archive", {
      "path" => "#{File.join(fixture_base, "src", "a.txt")},#{PluginSpecHelper.tmp_path("does-not-exist.txt")}",
      "dest" => dest,
    })

    result["dest_state"].as_s.must_equal("incomplete")
    result["missing"].as_a.map(&.as_s).must_equal([PluginSpecHelper.tmp_path("does-not-exist.txt")])
  end

  it "reports dest_state: absent and changed: false, without creating dest, when nothing is found" do
    dest = dest_path("nothing.tar.gz")
    File.delete(dest) if File.exists?(dest)

    result = PluginSpecHelper.run("archive", {"path" => File.join(fixture_base, "totally-missing.txt"), "dest" => dest})

    result["dest_state"].as_s.must_equal("absent")
    result["changed"].as_bool.must_equal(false)
    File.exists?(dest).must_equal(false)
  end

  # Real fails with `if not self.paths: module.fail_json(...)` when
  # NOTHING survives the exclude_path subtraction - and real's self.paths
  # still contains missing literal paths at that point, so a merely
  # absent source does NOT trigger this (that is the dest_state: absent
  # case above). Captured live against community.general 12.5.0 /
  # ansible-core 2.19.11: the fatal dump carries the original path list
  # joined with ", " plus both expanded lists (exclude duplicates kept).
  it "fails with real's exact 'no source paths were found' message when exclude_path removes every source" do
    missing = PluginSpecHelper.tmp_path("all-excluded-out2.txt")
    sub = PluginSpecHelper.tmp_path("all-excluded-sub")

    result = PluginSpecHelper.run("archive", {
      "path"          => missing,
      "exclude_path"  => "#{sub},#{missing},#{missing}",
      "force_archive" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error, no source paths were found")
    result["path"].as_s.must_equal(missing)
    result["expanded_paths"].as_s.must_equal(missing)
    result["expanded_exclude_paths"].as_s.must_equal("#{sub}, #{missing}, #{missing}")
  end

  it "fails with an empty expanded_paths string when only unmatched globs were given" do
    result = PluginSpecHelper.run("archive", {
      "path" => File.join(fixture_base, "no-glob-match-*.txt"),
      "dest" => dest_path("glob-empty.tar.gz"),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error, no source paths were found")
    result["expanded_paths"].as_s.must_be_empty
  end

  it "removes the source after a successful archive when remove: true" do
    source_dir = PluginSpecHelper.tmp_path("removeme")
    FileUtils.mkdir_p(source_dir)
    File.write(File.join(source_dir, "f.txt"), "x")
    dest = dest_path("removed.tar.gz")

    PluginSpecHelper.run("archive", {"path" => source_dir, "dest" => dest, "remove" => "true"})

    Dir.exists?(source_dir).must_equal(false)
  end

  describe "attributes: (chattr)" do
    # Real bug found via a proactive scope-cut audit: attributes: was
    # entirely unimplemented. Verified against real AnsibleModule's own
    # set_attributes_if_different source: unconditional (no filesystem-
    # support gate), fails the task with a clear message on a real
    # chattr error. This spec sandbox has no CAP_LINUX_IMMUTABLE (not
    # root), so a real `chattr +i` genuinely fails here - confirmed
    # directly against the real chattr binary before writing this -
    # which is exactly what's being verified: the failure propagates as
    # a real task failure instead of being silently swallowed.
    it "fails the task when the real chattr command fails" do
      dest = dest_path("attributes-fail.gz")
      result = PluginSpecHelper.run("archive", {
        "path" => File.join(fixture_base, "src", "a.txt"), "dest" => dest, "attributes" => "+i",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("chattr failed")
    end
  end

  describe "seuser:/serole:/setype:/selevel: (SELinux context)" do
    # Real bug found via the same audit: these were entirely
    # unimplemented. Verified against real AnsibleModule's own
    # selinux_enabled()/set_context_if_different source: real Ansible
    # skips this ENTIRELY (no chcon attempt at all) when SELinux isn't
    # enabled on the target - this dev sandbox has no /sys/fs/selinux at
    # all, so this confirms the archive itself still succeeds cleanly
    # (a true no-op, matching real Ansible's own verified behavior)
    # rather than attempting (and failing) a chcon call regardless.
    it "does not fail the archive when SELinux isn't enabled on the target (a true no-op, matching real Ansible)" do
      dest = dest_path("selinux-noop.gz")
      result = PluginSpecHelper.run("archive", {
        "path" => File.join(fixture_base, "src", "a.txt"), "dest" => dest,
        "seuser" => "system_u", "setype" => "etc_t",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
    end
  end

  it "fails with a clear message when path or dest is missing" do
    result = PluginSpecHelper.run("archive", {"dest" => dest_path("x.tar.gz")})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("path")
  end
end
