require "../spec_helper"
require "file_utils"
require "digest/sha1"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def as_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "assemble plugin" do
  it "concatenates fragments in alphabetical order" do
    src = as_path("assemble_src")
    dest = as_path("assemble_dest.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "10-first"), "first\n")
    File.write(File.join(src, "20-second"), "second\n")
    File.delete(dest) if File.exists?(dest)

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    File.read(dest).should eq("first\nsecond\n")
  end

  it "is idempotent when dest already matches the assembled content" do
    src = as_path("assemble_src_idem")
    dest = as_path("assemble_dest_idem.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "a"), "one\n")
    PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest})

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest})

    result["changed"].as_bool.should be_false
  end

  it "inserts delimiter: between fragments" do
    src = as_path("assemble_src_delim")
    dest = as_path("assemble_dest_delim.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "a"), "one")
    File.write(File.join(src, "b"), "two")
    File.delete(dest) if File.exists?(dest)

    PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest, "delimiter" => "---"})

    File.read(dest).should eq("one---\ntwo")
  end

  it "filters fragments by regexp:" do
    src = as_path("assemble_src_regexp")
    dest = as_path("assemble_dest_regexp.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "keep.conf"), "keep\n")
    File.write(File.join(src, "skip.txt"), "skip\n")
    File.delete(dest) if File.exists?(dest)

    PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest, "regexp" => "\\.conf$"})

    File.read(dest).should eq("keep\n")
  end

  it "skips hidden fragments when ignore_hidden: true" do
    src = as_path("assemble_src_hidden")
    dest = as_path("assemble_dest_hidden.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, ".hidden"), "hidden\n")
    File.write(File.join(src, "visible"), "visible\n")
    File.delete(dest) if File.exists?(dest)

    PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest, "ignore_hidden" => "true"})

    File.read(dest).should eq("visible\n")
  end

  it "writes a timestamped backup when backup: true and dest changes" do
    src = as_path("assemble_src_backup")
    dest = as_path("assemble_dest_backup.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(dest, "old content\n")
    File.write(File.join(src, "a"), "new content\n")

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest, "backup" => "true"})

    backup_file = result["backup_file"].as_s
    backup_file.should_not be_empty
    File.read(backup_file).should eq("old content\n")
  end

  it "fails when src doesn't exist" do
    result = PluginSpecHelper.run("assemble", {"src" => as_path("no-such-dir"), "dest" => as_path("irrelevant.conf")})

    result["failed"].as_bool.should be_true
  end

  it "reports a SHA1 checksum (real Ansible's own checksum:, not MD5) plus an md5sum: for back-compat" do
    src = as_path("assemble_src_checksum")
    dest = as_path("assemble_dest_checksum.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "a"), "content\n")
    File.delete(dest) if File.exists?(dest)

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest})

    result["checksum"].as_s.should eq(Digest::SHA1.hexdigest("content\n"))
    result["checksum"].as_s.size.should eq(40)
    result["md5sum"].as_s.size.should eq(32)
  end

  it "always reports msg: OK (real Ansible never varies this message)" do
    src = as_path("assemble_src_msg")
    dest = as_path("assemble_dest_msg.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "a"), "same\n")
    PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest})

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should eq("OK")
  end

  it "passes validation and writes dest (validate: with %s)" do
    src = as_path("assemble_src_validate_ok")
    dest = as_path("assemble_dest_validate_ok.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "a"), "value=1\n")
    File.delete(dest) if File.exists?(dest)

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest, "validate" => "grep -q '^value=1' %s"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    File.read(dest).should eq("value=1\n")
  end

  it "fails validation and leaves dest untouched" do
    src = as_path("assemble_src_validate_fail")
    dest = as_path("assemble_dest_validate_fail.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "a"), "value=BAD\n")
    File.write(dest, "original\n")

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest, "validate" => "! grep -q BAD %s"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("failed to validate")
    File.read(dest).should eq("original\n")
  end

  it "fails when validate: does not contain %s" do
    src = as_path("assemble_src_validate_nos")
    dest = as_path("assemble_dest_validate_nos.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "a"), "value=1\n")
    File.delete(dest) if File.exists?(dest)

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest, "validate" => "/bin/true"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("validate must contain %s")
  end

  it "applies owner/group/mode and reports add_path_info stat fields" do
    src = as_path("assemble_src_attrs")
    dest = as_path("assemble_dest_attrs.conf")
    FileUtils.rm_rf(src)
    Dir.mkdir_p(src)
    File.write(File.join(src, "a"), "x\n")
    File.delete(dest) if File.exists?(dest)

    result = PluginSpecHelper.run("assemble", {"src" => src, "dest" => dest, "mode" => "0640"})

    result["mode"].as_s.should eq("0640")
    result["uid"].as_i64.should eq(File.info(dest, follow_symlinks: false).owner_id.to_i64)
    result["state"].as_s.should eq("file")
  end
end
