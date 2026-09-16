require "../spec_helper"
require "file_utils"

# state=touch's result shape, live-verified against ansible-core 2.19.4
# (all four shapes: existing/new path x real run/check mode):
#
#   existing + real : changed/dest + the full add_path_info stat set
#                     (uid/gid/owner/group/mode/state "file"/size), no msg
#   existing + check: identical to the real run (the file exists, so the
#                     stat set is merged; still no msg)
#   new + real     : changed/dest + the stat set, no msg
#   new + check    : changed/dest ONLY - no stat fields (nothing exists
#                     to stat), no msg, and never a "state": "touch" echo
#                     (real Ansible's file module never emits the literal
#                     resolved state for touch)
describe "file state=touch result shape (live-verified vs ansible-core 2.19.4)" do
  it "existing file, real run: dest + full stat fields, no msg" do
    path = File.tempname("touch-exists-real")
    File.write(path, "hi\n")
    File.chmod(path, 0o640)

    result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch"})

    result["changed"].as_bool.should be_true
    result["dest"].as_s.should eq(path)
    result["mode"].as_s.should eq("0640")
    result["state"].as_s.should eq("file")
    result["size"].as_i64.should eq(3)
    result["owner"].as_s.should_not be_empty
    result["group"].as_s.should_not be_empty
    result["uid"]?.should_not be_nil
    result["gid"]?.should_not be_nil
    result["msg"]?.should be_nil
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "existing file, check mode: same dest + stat fields, no msg" do
    path = File.tempname("touch-exists-check")
    File.write(path, "hi\n")
    File.chmod(path, 0o640)

    result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.should be_true
    result["dest"].as_s.should eq(path)
    result["mode"].as_s.should eq("0640")
    result["state"].as_s.should eq("file")
    result["msg"]?.should be_nil
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "new file, real run: dest + stat fields, no msg, mode follows umask" do
    path = File.tempname("touch-new-real")
    old_mask = LibC.umask(0o002)
    begin
      result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch"})

      result["changed"].as_bool.should be_true
      result["dest"].as_s.should eq(path)
      result["mode"].as_s.should eq("0664")
      result["state"].as_s.should eq("file")
      result["msg"]?.should be_nil
      File.info(path).permissions.value.should eq(0o664)
    ensure
      LibC.umask(old_mask)
    end
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "new file, check mode: changed + dest only (no stat fields, no msg, no state echo)" do
    path = File.tempname("touch-new-check")

    result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.should be_true
    result["dest"].as_s.should eq(path)
    result.as_h.size.should eq(2)
    result["msg"]?.should be_nil
    result["state"]?.should be_nil
    File.exists?(path).should be_false
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
