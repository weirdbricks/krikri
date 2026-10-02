require "../minitest_helper"
require "json"

# Regression tests for the divergences a krikri-playbook-generator
# re-sweep (seed 35) flagged: deploy_helper's state=clean crash on a
# tree never created by state=present (kpg35 #30 - real's
# remove_unfinished_builds does a bare os.listdir on releases_path and
# the raw OSError kills the module) and the surrounding clean/finalize
# flow semantics live-verified against real ansible-playbook 2.19.11
# (ansible_connection=local, no gather caching). filesystem's fstype
# choices-order divergence (#53) is unmatchable by design - real builds
# its choices from a Python set, so the order differs on every real
# process; that is masked in the generator (see the generator repo's
# masks.cr) and covered by a membership-only assertion here.

describe "deploy_helper plugin - clean/finalize crash and cleanup flow (kpg35)" do
  it "state=clean crashes with real's bare-os.listdir OSError when the tree was never created" do
    root = PluginSpecHelper.tmp_path("kpg35-deploy-clean-missing")

    result = PluginSpecHelper.run("deploy_helper", {
      "clean"         => "true",
      "current_path"  => "/tmp/kpg35-no-such-current",
      "keep_releases" => "34",
      "mode"          => "0644",
      "owner"         => "root",
      "path"          => root,
      "release"       => "dkvakl",
      "state"         => "clean",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Task failed: Module failed: [Errno 2] No such file or directory: '#{root}/releases'")
  end

  it "state=clean crashes with Not a directory when releases_path is a file" do
    root = PluginSpecHelper.tmp_path("kpg35-deploy-clean-file")
    Dir.mkdir_p(root)
    File.write(File.join(root, "releases"), "not a directory")

    result = PluginSpecHelper.run("deploy_helper", {"path" => root, "state" => "clean"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Task failed: Module failed: [Errno 20] Not a directory: '#{root}/releases'")
  end

  it "state=finalize creates the dangling current symlink first, then crashes on the missing releases dir" do
    root = PluginSpecHelper.tmp_path("kpg35-deploy-finalize-fresh")
    Dir.mkdir_p(root)

    result = PluginSpecHelper.run("deploy_helper",
      {"path" => root, "state" => "finalize", "release" => "r1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Task failed: Module failed: [Errno 2] No such file or directory: '#{root}/releases'")
    File.symlink?(File.join(root, "current")).must_equal(true)
    File.readlink(File.join(root, "current")).must_equal("#{root}/releases/r1")
  end

  it "state=finalize without release fails real's required_if check" do
    root = PluginSpecHelper.tmp_path("kpg35-deploy-finalize-norelease")

    result = PluginSpecHelper.run("deploy_helper", {"path" => root, "state" => "finalize"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("state is finalize but all of the following are missing: release")
  end

  it "state=finalize fails real's keep_releases guard before touching anything" do
    root = PluginSpecHelper.tmp_path("kpg35-deploy-finalize-keep0")

    result = PluginSpecHelper.run("deploy_helper",
      {"path" => root, "state" => "finalize", "release" => "r1", "keep_releases" => "0"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("'keep_releases' should be at least 1")
  end

  it "state=clean removes unfinished builds and old releases past keep_releases in real's ctime order" do
    root = PluginSpecHelper.tmp_path("kpg35-deploy-clean-full")
    releases = File.join(root, "releases")
    Dir.mkdir_p(File.join(releases, "r1"))
    Dir.mkdir_p(File.join(releases, "r2"))
    Dir.mkdir_p(File.join(releases, "r3"))
    Dir.mkdir_p(File.join(releases, "r4"))
    Dir.mkdir_p(File.join(releases, "r5"))
    # r2 is an unfinished build; r3/r4/r5 get progressively newer ctimes
    # (sleep-separated touches: tmpfs ctime granularity is coarse enough
    # that same-tick utimes tie, and ties are unmatchable by
    # construction - real's Python sort on equal ctimes depends on
    # listdir order).
    File.write(File.join(releases, "r2", "DEPLOY_UNFINISHED"), "")
    sleep 1
    File.touch(File.join(releases, "r3"))
    sleep 1
    File.touch(File.join(releases, "r4"))
    sleep 1
    File.touch(File.join(releases, "r5"))

    result = PluginSpecHelper.run("deploy_helper",
      {"path" => root, "state" => "clean", "keep_releases" => "2", "release" => "r3"})

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    # r2 (unfinished build) removed; r1 (oldest remaining ctime past
    # keep_releases=2, with the reserved r3 excluded) removed; r3/r4/r5
    # kept.
    Dir.children(releases).sort.must_equal(["r3", "r4", "r5"])
  end

  it "state=clean removes the release's unfinished link file at the project root" do
    root = PluginSpecHelper.tmp_path("kpg35-deploy-clean-link")
    Dir.mkdir_p(File.join(root, "releases", "r1"))
    File.write(File.join(root, "r1.DEPLOY_UNFINISHED"), "")

    result = PluginSpecHelper.run("deploy_helper",
      {"path" => root, "state" => "clean", "release" => "r1"})

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    File.exists?(File.join(root, "r1.DEPLOY_UNFINISHED")).must_equal(false)
    File.directory?(File.join(root, "releases", "r1")).must_equal(true)
  end

  it "state=clean does NOT protect the release current points at (real deletes it, symlink dangles)" do
    root = PluginSpecHelper.tmp_path("kpg35-deploy-clean-current")
    releases = File.join(root, "releases")
    Dir.mkdir_p(File.join(releases, "r1"))
    Dir.mkdir_p(File.join(releases, "r4"))
    File.symlink(File.join(releases, "r4"), File.join(root, "current"))
    sleep 1
    File.write(File.join(releases, "r1"), "") unless File.directory?(File.join(releases, "r1"))

    result = PluginSpecHelper.run("deploy_helper",
      {"path" => root, "state" => "clean", "keep_releases" => "1"})

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    Dir.children(releases).must_equal(["r1"])
    File.symlink?(File.join(root, "current")).must_equal(true)
    File.readlink(File.join(root, "current")).must_equal("#{releases}/r4")
    File.exists?(File.join(releases, "r4")).must_equal(false)
  end

  it "state=clean in check mode counts the changes without deleting anything" do
    root = PluginSpecHelper.tmp_path("kpg35-deploy-clean-check")
    releases = File.join(root, "releases")
    Dir.mkdir_p(File.join(releases, "r1"))
    Dir.mkdir_p(File.join(releases, "r2"))
    Dir.mkdir_p(File.join(releases, "r3"))
    File.write(File.join(releases, "r2", "DEPLOY_UNFINISHED"), "")
    File.write(File.join(root, "r1.DEPLOY_UNFINISHED"), "")

    result = PluginSpecHelper.run("deploy_helper",
      {"path" => root, "state" => "clean", "keep_releases" => "1", "release" => "r1",
       "_ansible_check_mode" => "true"})

    result["failed"]?.must_be_nil
    # unfinished link is skipped in check mode (real's guard), the
    # unfinished build counts 1, and cleanup counts 3 dirs - 1 reserved
    # - 1 kept = 2.
    result["changed"].as_bool.must_equal(true)
    Dir.children(releases).sort.must_equal(["r1", "r2", "r3"])
    File.exists?(File.join(root, "r1.DEPLOY_UNFINISHED")).must_equal(true)
  end
end

describe "filesystem plugin - fstype choices membership (kpg35)" do
  # Real builds its fstype choices from a Python set
  # (filesystem.py's `fstypes = set(FILESYSTEMS.keys()) - ...`), so the
  # ORDER of the "value of fstype must be one of:" list is random per
  # real process (verified: five consecutive real runs each printed a
  # different order). Only the membership is matchable - the generator
  # masks the list (FSTYPE-SET-ORDER mask); this spec pins membership
  # and the deterministic tail.
  it "rejects a bogus fstype with real's membership and wording" do
    result = PluginSpecHelper.run("filesystem",
      {"dev" => "/tmp/kpg35-no-such-dev", "fstype" => "43"})

    result["failed"].as_bool.must_equal(true)
    msg = result["msg"].as_s
    msg.must_include("got: 43")
    list_part = msg[/value of fstype must be one of: (.*), got: /, 1]
    list_part.wont_be_nil
    names = list_part.not_nil!.split(", ")
    names.sort!.must_equal(%w[bcachefs btrfs ext2 ext3 ext4 ext4dev f2fs lvm ocfs2 reiserfs swap ufs vfat xfs].sort)
  end
end
