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
  it "matches stat -f exactly for every mount-space field on / and /tmp" do
    {"/", "/tmp"}.each do |mount|
      parts = `stat -f --format='%S %b %f %a %c %d' #{mount}`.strip.split(" ").map(&.to_i64)
      block_size, block_total, block_free, block_available, inode_total, inode_free = parts
      stats = Krikri::FactsGatherer.gather_mount_space_stats(mount)

      stats["block_size"].must_equal(block_size)
      stats["block_total"].must_equal(block_total)
      stats["block_available"].must_equal(block_available)
      stats["block_used"].must_equal(block_total - block_free)
      stats["size_total"].must_equal(block_size * block_total)
      stats["size_available"].must_equal(block_size * block_available)
      stats["inode_total"].must_equal(inode_total)
      stats["inode_available"].must_equal(inode_free)
      stats["inode_used"].must_equal(inode_total - inode_free)
    end
  end

  it "matches python3 os.statvfs f_frsize/f_blocks/f_bavail for block_size/size math" do
    python = Process.find_executable("python3")
    skip "python3 not available" unless python

    raw = Krikri::FactsGatherer.capture(python, ["-c",
                                                 "import os; s=os.statvfs('/'); print(s.f_frsize, s.f_blocks, s.f_bavail, s.f_files, s.f_favail)"])
    frsize, blocks, bavail, files, favail = raw.split(" ").map(&.to_i64)
    stats = Krikri::FactsGatherer.gather_mount_space_stats("/")

    stats["block_size"].must_equal(frsize)
    stats["block_total"].must_equal(blocks)
    stats["block_available"].must_equal(bavail)
    stats["inode_total"].must_equal(files)
    stats["inode_available"].must_equal(favail)
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
