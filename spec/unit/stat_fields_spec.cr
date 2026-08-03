require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/stat_fields"

describe CrystalPlay::PluginHelpers::StatFields do
  it "parses a regular file's stat -c output" do
    hash = CrystalPlay::PluginHelpers::StatFields.parse(
      "/tmp/f.txt",
      "644|12|1785641814|1785641832|1785641814|16582|37|1|1000|1000|labros|labros|regular file"
    ).as(Hash(String, JSON::Any))

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

  it "decodes rwx permission bits from the octal mode" do
    hash = CrystalPlay::PluginHelpers::StatFields.parse(
      "/tmp/f.txt",
      "750|0|0|0|0|1|1|1|0|0|root|root|regular file"
    ).as(Hash(String, JSON::Any))

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

  it "detects the setuid/setgid special bits from a 4-digit mode" do
    hash = CrystalPlay::PluginHelpers::StatFields.parse(
      "/tmp/f.txt",
      "4755|0|0|0|0|1|1|1|0|0|root|root|regular file"
    ).as(Hash(String, JSON::Any))

    hash["isuid"].as_bool.should be_true
    hash["isgid"].as_bool.should be_false
    hash["mode"].as_s.should eq("04755")
  end

  it "sets isdir for a directory" do
    hash = CrystalPlay::PluginHelpers::StatFields.parse(
      "/tmp/d",
      "755|4096|0|0|0|1|1|2|0|0|root|root|directory"
    ).as(Hash(String, JSON::Any))

    hash["isdir"].as_bool.should be_true
    hash["isreg"].as_bool.should be_false
  end

  it "sets islnk for a symbolic link" do
    hash = CrystalPlay::PluginHelpers::StatFields.parse(
      "/tmp/l",
      "777|5|0|0|0|1|1|1|0|0|root|root|symbolic link"
    ).as(Hash(String, JSON::Any))

    hash["islnk"].as_bool.should be_true
    hash["isreg"].as_bool.should be_false
  end

  it "returns nil for malformed stat output" do
    CrystalPlay::PluginHelpers::StatFields.parse("/tmp/x", "not enough fields").should be_nil
  end

  describe ".file_type" do
    it "returns the trailing file-type word" do
      CrystalPlay::PluginHelpers::StatFields.file_type(
        "644|12|0|0|0|1|1|1|0|0|root|root|regular file"
      ).should eq("regular file")
    end

    it "returns nil for malformed output" do
      CrystalPlay::PluginHelpers::StatFields.file_type("garbage").should be_nil
    end
  end

  describe ".regular_file?" do
    it "is true for both 'regular file' and 'regular empty file'" do
      CrystalPlay::PluginHelpers::StatFields.regular_file?("regular file").should be_true
      CrystalPlay::PluginHelpers::StatFields.regular_file?("regular empty file").should be_true
      CrystalPlay::PluginHelpers::StatFields.regular_file?("directory").should be_false
    end
  end

  describe ".symlink?" do
    it "is true only for 'symbolic link'" do
      CrystalPlay::PluginHelpers::StatFields.symlink?("symbolic link").should be_true
      CrystalPlay::PluginHelpers::StatFields.symlink?("regular file").should be_false
    end
  end
end
