require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/stat_fields"

private REGULAR_FILE = LibC::S_IFREG
private DIRECTORY     = LibC::S_IFDIR
private SYMLINK       = LibC::S_IFLNK

describe CrystalPlay::PluginHelpers::StatFields do
  describe ".build" do
    it "builds the stat hash for a regular file from raw stat fields" do
      hash = CrystalPlay::PluginHelpers::StatFields.build(
        "/tmp/f.txt",
        mode: REGULAR_FILE | 0o644,
        size: 12_i64, uid: 1000_i64, gid: 1000_i64,
        pw_name: "labros", gr_name: "labros",
        atime: 1785641832_i64, mtime: 1785641814_i64, ctime: 1785641814_i64,
        inode: 16582_i64, dev: 37_i64, nlink: 1_i64
      )

      hash["exists"].as_bool.should be_true
      hash["path"].as_s.should eq("/tmp/f.txt")
      hash["mode"].as_s.should eq("0644")
      hash["size"].as_i64.should eq(12)
      hash["uid"].as_i64.should eq(1000)
      hash["gid"].as_i64.should eq(1000)
      hash["pw_name"].as_s.should eq("labros")
      hash["gr_name"].as_s.should eq("labros")
      hash["isreg"].as_bool.should be_true
      hash["isdir"].as_bool.should be_false
      hash["islnk"].as_bool.should be_false
    end

    it "decodes rwx permission bits from the mode" do
      hash = CrystalPlay::PluginHelpers::StatFields.build(
        "/tmp/f.txt", mode: REGULAR_FILE | 0o750,
        size: 0_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0_i64, mtime: 0_i64, ctime: 0_i64, inode: 1_i64, dev: 1_i64, nlink: 1_i64
      )

      hash["rusr"].as_bool.should be_true
      hash["wusr"].as_bool.should be_true
      hash["xusr"].as_bool.should be_true
      hash["rgrp"].as_bool.should be_true
      hash["wgrp"].as_bool.should be_false
      hash["xgrp"].as_bool.should be_true
      hash["roth"].as_bool.should be_false
      hash["woth"].as_bool.should be_false
      hash["xoth"].as_bool.should be_false
    end

    it "detects the setuid/setgid special bits and shows a 4-digit mode" do
      hash = CrystalPlay::PluginHelpers::StatFields.build(
        "/tmp/f.txt", mode: REGULAR_FILE | 0o4755,
        size: 0_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0_i64, mtime: 0_i64, ctime: 0_i64, inode: 1_i64, dev: 1_i64, nlink: 1_i64
      )

      hash["isuid"].as_bool.should be_true
      hash["isgid"].as_bool.should be_false
      hash["mode"].as_s.should eq("04755")
    end

    it "omits the special digit from mode when no special bits are set" do
      hash = CrystalPlay::PluginHelpers::StatFields.build(
        "/tmp/f.txt", mode: REGULAR_FILE | 0o644,
        size: 0_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0_i64, mtime: 0_i64, ctime: 0_i64, inode: 1_i64, dev: 1_i64, nlink: 1_i64
      )

      hash["mode"].as_s.should eq("0644")
    end

    it "sets isdir for a directory" do
      hash = CrystalPlay::PluginHelpers::StatFields.build(
        "/tmp/d", mode: DIRECTORY | 0o755,
        size: 4096_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0_i64, mtime: 0_i64, ctime: 0_i64, inode: 1_i64, dev: 1_i64, nlink: 2_i64
      )

      hash["isdir"].as_bool.should be_true
      hash["isreg"].as_bool.should be_false
    end

    it "sets islnk for a symbolic link" do
      hash = CrystalPlay::PluginHelpers::StatFields.build(
        "/tmp/l", mode: SYMLINK | 0o777,
        size: 5_i64, uid: 0_i64, gid: 0_i64, pw_name: "root", gr_name: "root",
        atime: 0_i64, mtime: 0_i64, ctime: 0_i64, inode: 1_i64, dev: 1_i64, nlink: 1_i64
      )

      hash["islnk"].as_bool.should be_true
      hash["isreg"].as_bool.should be_false
    end
  end

  describe ".regular_file?" do
    it "is true only for S_IFREG" do
      CrystalPlay::PluginHelpers::StatFields.regular_file?(REGULAR_FILE | 0o644).should be_true
      CrystalPlay::PluginHelpers::StatFields.regular_file?(DIRECTORY | 0o755).should be_false
    end
  end

  describe ".symlink?" do
    it "is true only for S_IFLNK" do
      CrystalPlay::PluginHelpers::StatFields.symlink?(SYMLINK | 0o777).should be_true
      CrystalPlay::PluginHelpers::StatFields.symlink?(REGULAR_FILE | 0o644).should be_false
    end
  end
end
