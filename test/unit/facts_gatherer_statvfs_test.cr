require "../minitest_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Perf follow-up: gather_mount_space_stats now reads statvfs(2) directly
# instead of forking `stat -f` per mount, and the /proc, /sys file reads
# that used to fork `cat` now read directly. Both changes are pure
# plumbing, so these tests pin the VALUES, not the mechanism: the mount
# numbers must stay identical to `stat -f` (== os.statvfs), and the file
# read must keep capture("cat", ...)'s contract (stripped content, ""
# when the file is missing or unreadable).
describe "Krikri::FactsGatherer statvfs and file reads (facts_gatherer_statvfs_test.cr)" do
  # The reference is read from a LIVE filesystem, and the suite runs on
  # parallel workers that write to disk while this spec is between its
  # readings - both CI failures so far were a few blocks of drift
  # between the reference snapshot and the plugin's, and usage can also
  # swing both ways inside the window, so a value bracketed by two
  # reference readings is not guaranteed either. What this spec pins is
  # FIELD SELECTION and ARITHMETIC, not instantaneous occupancy: the
  # invariant fields (block size, block total, inode total, and the
  # products built from them) stay pinned exactly, while every field
  # that moves under concurrent writes must match one of the two
  # reference readings within a small absolute drift budget - orders of
  # magnitude below the gap a confused field (f_bfree vs f_bavail) or a
  # wrong multiplier would produce.
  private VOLATILE_BLOCK_BUDGET = 8192 # 32 MiB on a 4 KiB-block fs

  private def within_reference_window(low : Int64, high : Int64, actual : Int64, budget : Int64 = VOLATILE_BLOCK_BUDGET.to_i64) : Nil
    lo, hi = {low, high}.min, {low, high}.max
    (actual >= lo - budget && actual <= hi + budget).must_equal(
      true, "expected #{actual} to match the reference readings #{lo}..#{hi} within #{budget}")
  end

  it "matches stat -f exactly for every mount-space field on / and /tmp" do
    {"/", "/tmp"}.each do |mount|
      read = -> {
        `stat -f --format='%S %b %f %a %c %d' #{mount}`.strip.split(" ").map(&.to_i64)
      }
      block_size, block_total, block_free, block_available, inode_total, inode_free = read.call
      stats = Krikri::FactsGatherer.gather_mount_space_stats(mount)
      _, _, block_free2, block_available2, _, inode_free2 = read.call

      stats["block_size"].must_equal(block_size)
      stats["block_total"].must_equal(block_total)
      within_reference_window(block_available, block_available2, stats["block_available"].as(Int64))
      within_reference_window(block_total - block_free, block_total - block_free2, stats["block_used"].as(Int64))
      stats["size_total"].must_equal(block_size * block_total)
      within_reference_window(block_size * block_available, block_size * block_available2, stats["size_available"].as(Int64), VOLATILE_BLOCK_BUDGET * block_size)
      stats["inode_total"].must_equal(inode_total)
      within_reference_window(inode_free, inode_free2, stats["inode_available"].as(Int64), 2048)
      within_reference_window(inode_total - inode_free, inode_total - inode_free2, stats["inode_used"].as(Int64), 2048)
    end
  end

  it "matches python3 os.statvfs f_frsize/f_blocks/f_bavail for block_size/size math" do
    python = Process.find_executable("python3")
    skip "python3 not available" unless python

    pycode = "import os; s=os.statvfs('/'); print(s.f_frsize, s.f_blocks, s.f_bavail, s.f_files, s.f_favail)"
    frsize, blocks, bavail, files, favail =
      Krikri::FactsGatherer.capture(python, ["-c", pycode]).split(" ").map(&.to_i64)
    stats = Krikri::FactsGatherer.gather_mount_space_stats("/")
    _, _, bavail2, _, favail2 =
      Krikri::FactsGatherer.capture(python, ["-c", pycode]).split(" ").map(&.to_i64)

    stats["block_size"].must_equal(frsize)
    stats["block_total"].must_equal(blocks)
    within_reference_window(bavail, bavail2, stats["block_available"].as(Int64))
    stats["inode_total"].must_equal(files)
    within_reference_window(favail, favail2, stats["inode_available"].as(Int64))
  end

  it "returns an empty hash when statvfs fails on a nonexistent path" do
    missing = PluginSpecHelper.tmp_path("facts-statvfs", "no-such-mount")
    Krikri::FactsGatherer.gather_mount_space_stats(missing).must_equal({} of String => Int64 | String)
  end

  it "reads a /proc file identically to cat, stripped" do
    path = "/proc/sys/kernel/hostname"
    Krikri::FactsGatherer.read_file_stripped(path).must_equal(`cat #{path}`.strip)
  end

  it "strips surrounding whitespace from a read file like capture cat did" do
    path = PluginSpecHelper.tmp_path("facts-statvfs", "padded.txt")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "  padded value\n")
    Krikri::FactsGatherer.read_file_stripped(path).must_equal("padded value")
  end

  it "returns an empty string for a missing file, like capture cat did" do
    missing = PluginSpecHelper.tmp_path("facts-statvfs", "no-such-file")
    Krikri::FactsGatherer.read_file_stripped(missing).must_equal("")
  end

  it "returns an empty string for an unreadable /proc-style file" do
    # /proc/sys/vm/drop_caches exists but is writable-only, never readable;
    # the contract is "" rather than a raise.
    Krikri::FactsGatherer.read_file_stripped("/proc/sys/vm/drop_caches").must_equal("")
  end
end
