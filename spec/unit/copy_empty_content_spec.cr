require "../spec_helper"
require "file_utils"

# `copy:` with an empty-string `content:` or `src:`.
#
# Real Ansible's copy action plugin truthiness-checks `src`, and
# ansible-core 2.19 (verified live against `hbjydev.restic`, round
# 702015) fails a `content:` that templates to "" with
# "src (or content) is required" instead of silently writing an empty
# file. krikri-playbook used to treat an empty-string param as present
# (non-nil check only) and succeeded, writing an empty
# /etc/restic/files where real ansible-playbook failed the task.
private def with_temp_dir(&)
  dir = File.tempname("copy-empty-content-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "copy: empty-string content/src counts as not provided" do
  it "fails with the real Ansible message for empty content and no src" do
    with_temp_dir do |dir|
      dest = File.join(dir, "files")

      result = PluginSpecHelper.run("copy", {
        "content" => "",
        "dest"    => dest,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("src (or content) is required")
      File.exists?(dest).should be_false
    end
  end

  it "leaves an existing destination untouched when content is empty" do
    # Real Ansible fails in the action plugin, before anything is
    # written - a pre-existing dest must not be truncated to empty.
    with_temp_dir do |dir|
      dest = File.join(dir, "files")
      File.write(dest, "original\n")

      result = PluginSpecHelper.run("copy", {
        "content" => "",
        "dest"    => dest,
      })

      result["failed"].as_bool.should be_true
      File.read(dest).should eq("original\n")
    end
  end

  it "fails the same way for an empty-string src and no content" do
    # src has always been truthiness-checked in real Ansible, so
    # src: "" is "not provided" too.
    with_temp_dir do |dir|
      dest = File.join(dir, "out")

      result = PluginSpecHelper.run("copy", {
        "src"  => "",
        "dest" => dest,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("src (or content) is required")
      File.exists?(dest).should be_false
    end
  end

  it "uses content when src is an empty string" do
    # src: "" is ignored rather than "mutually exclusive" - the empty
    # string falls out of the truthiness check, leaving the content
    # path to run.
    with_temp_dir do |dir|
      dest = File.join(dir, "out")

      result = PluginSpecHelper.run("copy", {
        "src"     => "",
        "content" => "hello\n",
        "dest"    => dest,
      })

      result["failed"]?.try(&.as_bool).should_not be_true
      result["changed"].as_bool.should be_true
      File.read(dest).should eq("hello\n")
    end
  end
end
