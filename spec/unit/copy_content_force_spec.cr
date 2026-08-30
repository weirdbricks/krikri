require "../spec_helper"
require "file_utils"

# `copy:` with `content:` + `force: false` against an EXISTING file.
#
# Real Ansible's `force: false` means "only put it there if it is not
# there already" - an existing destination is left completely alone,
# content and all, and the task reports ok/changed=false.
#
# copy.cr honoured that on the `src:` path but not on the `content:`
# path, which never consulted `force` at all: it compared checksums, saw
# a difference, and overwrote. Found live on `mrlesmithjr.mdadm`, whose
# "Arrays | Ensure mdadm conf file exists" task is exactly
# `content: "" / force: false` aimed at the distro's own
# /etc/mdadm/mdadm.conf. Real ansible-playbook left the 688-byte file
# untouched and reported ok; krikri-playbook truncated it to 0 bytes and
# reported changed. That is data loss, not a cosmetic verdict
# difference, which is why this is pinned at the plugin level rather
# than left to the benchmark round that caught it.
private def with_temp_dir(&)
  dir = File.tempname("copy-force-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "copy: content with force: false" do
  it "leaves an existing file untouched and reports no change" do
    with_temp_dir do |dir|
      dest = File.join(dir, "existing.conf")
      File.write(dest, "original content\n")

      result = PluginSpecHelper.run("copy", {
        "content" => "",
        "dest"    => dest,
        "force"   => "false",
      })

      result["changed"].as_bool.should be_false
      result["failed"]?.try(&.as_bool).should_not be_true
      # The load-bearing assertion: the bytes are still there.
      File.read(dest).should eq("original content\n")
    end
  end

  it "still creates the file when it does not exist" do
    # force: false is "create if absent", not "never write".
    with_temp_dir do |dir|
      dest = File.join(dir, "new.conf")

      result = PluginSpecHelper.run("copy", {
        "content" => "hello\n",
        "dest"    => dest,
        "force"   => "false",
      })

      result["changed"].as_bool.should be_true
      File.read(dest).should eq("hello\n")
    end
  end

  it "still overwrites when force is left at its default" do
    # The default is force: true, so the ordinary case must be
    # unaffected by the fix.
    with_temp_dir do |dir|
      dest = File.join(dir, "existing.conf")
      File.write(dest, "original content\n")

      result = PluginSpecHelper.run("copy", {
        "content" => "replaced\n",
        "dest"    => dest,
      })

      result["changed"].as_bool.should be_true
      File.read(dest).should eq("replaced\n")
    end
  end

  it "reports no change for identical content regardless of force" do
    # The pre-existing idempotency path must still win before the force
    # check has anything to say.
    with_temp_dir do |dir|
      dest = File.join(dir, "same.conf")
      File.write(dest, "same\n")

      result = PluginSpecHelper.run("copy", {
        "content" => "same\n",
        "dest"    => dest,
      })

      result["changed"].as_bool.should be_false
      File.read(dest).should eq("same\n")
    end
  end
end
