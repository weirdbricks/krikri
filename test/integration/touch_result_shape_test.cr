require "../minitest_helper"
require "file_utils"

# Every spec gets its own tmp_path subtree (see minitest_helper).
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

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
#                     (Ansible's file module never emits the literal
#                     resolved state for touch)
describe "file state=touch result shape (live-verified vs ansible-core 2.19.4)" do
  it "existing file, real run: dest + full stat fields, no msg" do
    path = File.tempname("touch-exists-real")
    File.write(path, "hi\n")
    File.chmod(path, 0o640)

    result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch"})

    result["changed"].as_bool.must_equal(true)
    result["dest"].as_s.must_equal(path)
    result["mode"].as_s.must_equal("0640")
    result["state"].as_s.must_equal("file")
    result["size"].as_i64.must_equal(3)
    result["owner"].as_s.wont_be_empty
    result["group"].as_s.wont_be_empty
    result["uid"]?.wont_be_nil
    result["gid"]?.wont_be_nil
    result["msg"]?.must_be_nil
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "existing file, check mode: same dest + stat fields, no msg" do
    path = File.tempname("touch-exists-check")
    File.write(path, "hi\n")
    File.chmod(path, 0o640)

    result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["dest"].as_s.must_equal(path)
    result["mode"].as_s.must_equal("0640")
    result["state"].as_s.must_equal("file")
    result["msg"]?.must_be_nil
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "new file, real run: dest + stat fields, no msg, mode follows umask" do
    path = File.tempname("touch-new-real")
    old_mask = LibC.umask(0o002)
    begin
      result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch"})

      result["changed"].as_bool.must_equal(true)
      result["dest"].as_s.must_equal(path)
      result["mode"].as_s.must_equal("0664")
      result["state"].as_s.must_equal("file")
      result["msg"]?.must_be_nil
      File.info(path).permissions.value.must_equal(0o664)
    ensure
      LibC.umask(old_mask)
    end
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "new file, check mode: changed + dest only (no stat fields, no msg, no state echo)" do
    path = File.tempname("touch-new-check")

    result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["dest"].as_s.must_equal(path)
    result.as_h.size.must_equal(2)
    result["msg"]?.must_be_nil
    result["state"]?.must_be_nil
    File.exists?(path).must_equal(false)
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end

# file.py's execute_touch always attaches a diff - initial_diff seeds
# before/after with path plus the state transition to "touch" (get_state()
# never reports "touch", so the pair always differs), basic.py's attribute
# setters add one entry per attribute that actually changes, and
# update_timestamp_for_file adds mtime/atime for the axes whose value
# changes. Live-verified against ansible-core 2.21.6 --diff, including the
# exact hunk line counts in issue #1441's kpg template pair.
describe "file state=touch diff payload (issue #1441, live-verified vs 2.21.6)" do
  it "diffs the state transition and a changed mode for an existing file" do
    path = tmp_path("touch-diff-mode.txt")
    File.write(path, "hi\n")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("file", {
      "path"              => path,
      "state"             => "touch",
      "mode"              => "0755",
      "modification_time" => "preserve",
      "access_time"       => "preserve",
      "_ansible_diff"     => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["diff"]["before"].as_h.keys.must_equal(["path", "state", "mode"])
    result["diff"]["before"]["path"].as_s.must_equal(path)
    result["diff"]["before"]["state"].as_s.must_equal("file")
    result["diff"]["before"]["mode"].as_s.must_equal("0644")
    result["diff"]["after"].as_h.keys.must_equal(["path", "state", "mode"])
    result["diff"]["after"]["state"].as_s.must_equal("touch")
    result["diff"]["after"]["mode"].as_s.must_equal("0755")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "diffs an absent -> touch transition, with no attribute entries, for a new file" do
    path = tmp_path("touch-diff-new.txt")

    result = PluginSpecHelper.run("file", {
      "path"              => path,
      "state"             => "touch",
      "modification_time" => "preserve",
      "access_time"       => "preserve",
      "_ansible_diff"     => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["diff"]["before"].as_h.keys.must_equal(["path", "state"])
    result["diff"]["before"]["state"].as_s.must_equal("absent")
    result["diff"]["after"].as_h.keys.must_equal(["path", "state"])
    result["diff"]["after"]["state"].as_s.must_equal("touch")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  # "now" is the default for state=touch, and Ansible resolves BOTH "now"
  # axes from one time.time() value - the after side therefore prints the
  # same number for mtime and atime (the before side keeps each axis'
  # current stat value, so it need not match).
  it "diffs both timestamp axes when neither modification_time nor access_time is given" do
    path = tmp_path("touch-diff-now.txt")
    File.write(path, "hi\n")
    past = Time.utc - 1.hour
    File.utime(past, past, path)

    result = PluginSpecHelper.run("file", {
      "path"          => path,
      "state"         => "touch",
      "_ansible_diff" => "true",
    })

    diff = result["diff"]
    diff["before"].as_h.keys.sort!.must_equal(["atime", "mtime", "path", "state"])
    diff["after"].as_h.keys.sort!.must_equal(["atime", "mtime", "path", "state"])
    diff["after"]["mtime"].as_f.must_equal(diff["after"]["atime"].as_f)
    (diff["after"]["mtime"].as_f > diff["before"]["mtime"].as_f).must_equal(true)
    diff["before"]["state"].as_s.must_equal("file")
    diff["after"]["state"].as_s.must_equal("touch")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  # A NEW path (kpg playbook 000021-multi-file-happy, issue #1503): the
  # file did not exist when the task started, so initial_diff() diffs
  # "absent" against "touch", and update_timestamp_for_file still adds an
  # atime/mtime pair on BOTH sides - the file's just-created stat times
  # versus the "now" Ansible reads for the utime(None) it applies. Those
  # floats are each engine's own wall clock, so two runs can never agree on
  # them (see KNOWN_MISSING.md); this pins the shape the comparison
  # harness's epoch mask anchors on: the same four keys on both sides, the
  # after pair being one shared "now" value, and the state transition on its
  # own line.
  it "diffs absent -> touch with an atime/mtime pair on both sides for a new file" do
    path = tmp_path("touch-diff-new-now.txt")

    result = PluginSpecHelper.run("file", {
      "path"          => path,
      "state"         => "touch",
      "_ansible_diff" => "true",
    })

    diff = result["diff"]
    diff["before"].as_h.keys.sort!.must_equal(["atime", "mtime", "path", "state"])
    diff["after"].as_h.keys.sort!.must_equal(["atime", "mtime", "path", "state"])
    diff["before"]["state"].as_s.must_equal("absent")
    diff["after"]["state"].as_s.must_equal("touch")
    diff["after"]["mtime"].as_f.must_equal(diff["after"]["atime"].as_f)
    (diff["after"]["mtime"].as_f > diff["before"]["mtime"].as_f).must_equal(true)
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  # Ansible attaches the diff even when the task is idempotent (changed:
  # false); the callback's own changed-gate is what keeps the block off the
  # screen, not the module.
  it "keeps the state transition in the result when nothing changed" do
    path = tmp_path("touch-diff-unchanged.txt")
    File.write(path, "hi\n")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("file", {
      "path"              => path,
      "state"             => "touch",
      "mode"              => "0644",
      "modification_time" => "preserve",
      "access_time"       => "preserve",
      "_ansible_diff"     => "true",
    })

    result["changed"].as_bool.must_equal(false)
    result["diff"]["before"].as_h.keys.must_equal(["path", "state"])
    result["diff"]["before"]["state"].as_s.must_equal("file")
    result["diff"]["after"]["state"].as_s.must_equal("touch")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "carries no diff container unless diff mode is on" do
    path = tmp_path("touch-diff-off.txt")
    File.write(path, "hi\n")

    result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch"})

    result["diff"]?.must_be_nil
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
