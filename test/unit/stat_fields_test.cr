require "../minitest_helper"
require "../../src/krikri/plugin_helpers/stat_fields"

private REGULAR_FILE = LibC::S_IFREG
private DIRECTORY    = LibC::S_IFDIR
private SYMLINK      = LibC::S_IFLNK

describe Krikri::PluginHelpers::StatFields do
  describe ".build" do
    it "builds the stat hash for a regular file from raw stat fields" do
      hash = Krikri::PluginHelpers::StatFields.build(
        "/tmp/f.txt",
        mode: REGULAR_FILE | 0o644,
        size: 12_i64, uid: 1000_i64, gid: 1000_i64,
        pw_name: "labros", gr_name: "labros",
        atime: 1785641832.764945_f64, mtime: 1785641814.25_f64, ctime: 1785641814.0_f64,
        inode: 16582_i64, dev: 37_i64, nlink: 1_i64,
        block_size: 4096_i64, blocks: 8_i64, device_type: 0_i64
      )

      hash["exists"].as_bool.must_equal(true)
      hash["path"].as_s.must_equal("/tmp/f.txt")
      hash["mode"].as_s.must_equal("0644")
      hash["size"].as_i64.must_equal(12)
      hash["uid"].as_i64.must_equal(1000)
      hash["gid"].as_i64.must_equal(1000)
      hash["pw_name"].as_s.must_equal("labros")
      hash["gr_name"].as_s.must_equal("labros")
      hash["atime"].as_f.must_equal(1785641832.764945)
      hash["mtime"].as_f.must_equal(1785641814.25)
      hash["ctime"].as_f.must_equal(1785641814.0)
      hash["isreg"].as_bool.must_equal(true)
      hash["isdir"].as_bool.must_equal(false)
      hash["islnk"].as_bool.must_equal(false)
    end

    it "serializes sub-second timestamps as JSON floats, not ints or strings" do
      hash = Krikri::PluginHelpers::StatFields.build(
        "/tmp/f.txt", mode: REGULAR_FILE | 0o644,
        size: 0_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 1789308974.764945_f64, mtime: 1789308974.5_f64, ctime: 1789308974.0_f64,
        inode: 1_i64, dev: 37_i64, nlink: 1_i64,
        block_size: 4096_i64, blocks: 8_i64, device_type: 0_i64
      )

      JSON.parse(hash["atime"].to_json).as_f.must_equal(1789308974.764945)
      JSON.parse(hash["mtime"].to_json).as_f.must_equal(1789308974.5)
      hash["ctime"].to_json.must_equal("1789308974.0")
    end

    it "exposes block_size/blocks/device_type passthroughs and no disk_usage_bytes" do
      hash = Krikri::PluginHelpers::StatFields.build(
        "/tmp/f.txt", mode: REGULAR_FILE | 0o644,
        size: 1000_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0.0_f64, mtime: 0.0_f64, ctime: 0.0_f64,
        inode: 1_i64, dev: 37_i64, nlink: 1_i64,
        block_size: 4096_i64, blocks: 8_i64, device_type: 0_i64
      )

      # Same stat.py definitions Ansible uses: raw st_blksize/
      # st_blocks/st_rdev. Ansible 2.19.11's stat result carries NO
      # disk_usage_bytes (live-verified: a stat of a 6-byte file with
      # blocks 8 returns block_size/blocks/device_type and nothing
      # else in that family), so krikri must not invent one.
      hash["block_size"].as_i64.must_equal(4096)
      hash["blocks"].as_i64.must_equal(8)
      hash["device_type"].as_i64.must_equal(0)
      hash.has_key?("disk_usage_bytes").must_equal(false)
    end

    it "decodes rwx permission bits from the mode" do
      hash = Krikri::PluginHelpers::StatFields.build(
        "/tmp/f.txt", mode: REGULAR_FILE | 0o750,
        size: 0_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0.0_f64, mtime: 0.0_f64, ctime: 0.0_f64, inode: 1_i64, dev: 1_i64, nlink: 1_i64,
        block_size: 4096_i64, blocks: 0_i64, device_type: 0_i64
      )

      hash["rusr"].as_bool.must_equal(true)
      hash["wusr"].as_bool.must_equal(true)
      hash["xusr"].as_bool.must_equal(true)
      hash["rgrp"].as_bool.must_equal(true)
      hash["wgrp"].as_bool.must_equal(false)
      hash["xgrp"].as_bool.must_equal(true)
      hash["roth"].as_bool.must_equal(false)
      hash["woth"].as_bool.must_equal(false)
      hash["xoth"].as_bool.must_equal(false)
    end

    it "detects the setuid/setgid special bits and shows a 4-digit mode" do
      hash = Krikri::PluginHelpers::StatFields.build(
        "/tmp/f.txt", mode: REGULAR_FILE | 0o4755,
        size: 0_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0.0_f64, mtime: 0.0_f64, ctime: 0.0_f64, inode: 1_i64, dev: 1_i64, nlink: 1_i64,
        block_size: 4096_i64, blocks: 0_i64, device_type: 0_i64
      )

      hash["isuid"].as_bool.must_equal(true)
      hash["isgid"].as_bool.must_equal(false)
      hash["mode"].as_s.must_equal("04755")
    end

    it "omits the special digit from mode when no special bits are set" do
      hash = Krikri::PluginHelpers::StatFields.build(
        "/tmp/f.txt", mode: REGULAR_FILE | 0o644,
        size: 0_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0.0_f64, mtime: 0.0_f64, ctime: 0.0_f64, inode: 1_i64, dev: 1_i64, nlink: 1_i64,
        block_size: 4096_i64, blocks: 0_i64, device_type: 0_i64
      )

      hash["mode"].as_s.must_equal("0644")
    end

    it "sets isdir for a directory" do
      hash = Krikri::PluginHelpers::StatFields.build(
        "/tmp/d", mode: DIRECTORY | 0o755,
        size: 4096_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0.0_f64, mtime: 0.0_f64, ctime: 0.0_f64, inode: 1_i64, dev: 1_i64, nlink: 2_i64,
        block_size: 4096_i64, blocks: 8_i64, device_type: 0_i64
      )

      hash["isdir"].as_bool.must_equal(true)
      hash["isreg"].as_bool.must_equal(false)
    end

    it "sets islnk for a symbolic link" do
      hash = Krikri::PluginHelpers::StatFields.build(
        "/tmp/l", mode: SYMLINK | 0o777,
        size: 5_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0.0_f64, mtime: 0.0_f64, ctime: 0.0_f64, inode: 1_i64, dev: 1_i64, nlink: 1_i64,
        block_size: 4096_i64, blocks: 0_i64, device_type: 0_i64
      )

      hash["islnk"].as_bool.must_equal(true)
      hash["isreg"].as_bool.must_equal(false)
    end
  end

  describe ".regular_file?" do
    it "is true only for S_IFREG" do
      Krikri::PluginHelpers::StatFields.regular_file?(REGULAR_FILE | 0o644).must_equal(true)
      Krikri::PluginHelpers::StatFields.regular_file?(DIRECTORY | 0o755).must_equal(false)
    end
  end

  describe ".symlink?" do
    it "is true only for S_IFLNK" do
      Krikri::PluginHelpers::StatFields.symlink?(SYMLINK | 0o777).must_equal(true)
      Krikri::PluginHelpers::StatFields.symlink?(REGULAR_FILE | 0o644).must_equal(false)
    end
  end
end
