require "../spec_helper"
require "file_utils"

# stat's error surface must match real stat.py's own try/except: ENOENT
# is the ONLY errno treated as a successful `exists: false`; every
# other OSError fails the task with strerror as the message. Previously
# every stat failure came back as exists: false - a stat whose parent
# is a FILE (ENOTDIR, e.g. probing dest/hostname after a flat: true
# fetch wrote dest as a plain file) silently reported exists: false
# where real ansible-playbook hard-fails with "Not a directory".
private def with_temp_dir(&)
  dir = File.tempname("stat-errno-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "stat errno surface" do
  it "fails with the OS error string when the parent is a file (ENOTDIR)" do
    with_temp_dir do |dir|
      parent = File.join(dir, "parent")
      File.write(parent, "i am a file, not a directory\n")

      result = PluginSpecHelper.run("stat", {"path" => File.join(parent, "child")})

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("Not a directory")
    end
  end

  it "reports exists: false for a plain missing path (ENOENT)" do
    with_temp_dir do |dir|
      result = PluginSpecHelper.run("stat", {"path" => File.join(dir, "no-such-file")})

      result["failed"]?.try(&.as_bool).should_not be_true
      result["stat"]["exists"].as_bool.should be_false
    end
  end

  it "reports exists: false (not ENOTDIR failure) when following a dangling symlink" do
    with_temp_dir do |dir|
      link = File.join(dir, "dangling")
      File.symlink(File.join(dir, "gone"), link)

      result = PluginSpecHelper.run("stat", {"path" => link, "follow" => "true"})

      result["failed"]?.try(&.as_bool).should_not be_true
      result["stat"]["exists"].as_bool.should be_false
    end
  end
end
