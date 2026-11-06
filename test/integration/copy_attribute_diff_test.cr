require "../minitest_helper"
require "file_utils"

# The file-attributes diff on copy/template's equal-content path.
#
# When the destination already holds the source's exact content, Ansible's
# copy action plugin skips the transfer and dispatches ansible.legacy.file
# instead (copy.py's `_copy_file`, "no need to transfer the file, already
# correct hash, but still need to call the file module in case we want to
# change attributes"). That file module builds file.py's own attribute
# diff: a DICT of before/after seeded with the path and carrying one entry
# per attribute that actually changes - not copy's usual content-diff LIST.
# krikri applied the attributes but emitted no diff at all, so a task that
# only fixed a stale mode/owner/group/attributes printed nothing under
# --diff. Live-verified byte for byte against ansible-core 2.21.6 (Rocky 9
# guest for the SELinux secontext entry, Ubuntu guest for the rest).
describe "copy/template equal-content attribute diff" do
  it "diffs a mode fix on the equal-content path as the file module does" do
    dir = PluginSpecHelper.tmp_path("copy-attr-diff-mode")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "dest.txt")
    File.write(dest, "hello")
    File.chmod(dest, 0o644)

    result = PluginSpecHelper.run("copy", {
      "content"       => "hello",
      "dest"          => dest,
      "mode"          => "0600",
      "_ansible_diff" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    diff = result["diff"].as_h
    diff["before"]["mode"].as_s.must_equal("0644")
    diff["after"]["mode"].as_s.must_equal("0600")
    diff["before"]["path"].as_s.must_equal(dest)
    diff["after"]["path"].as_s.must_equal(dest)
    # No other attribute was asked for, so no other entry appears.
    diff["before"].as_h.keys.sort!.must_equal(["mode", "path"])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "keeps the path-only diff dict when nothing needs reconciling" do
    # Real still records the seeded {"path": ...} pair on a no-op run -
    # the callback prints nothing for it because no lines differ, but the
    # registered result's `diff` key is this dict (live-verified vs
    # 2.21.6 via a register + debug).
    dir = PluginSpecHelper.tmp_path("copy-attr-diff-noop")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "dest.txt")
    File.write(dest, "hello")

    result = PluginSpecHelper.run("copy", {
      "content"       => "hello",
      "dest"          => dest,
      "_ansible_diff" => "true",
    })

    result["changed"].as_bool.must_equal(false)
    diff = result["diff"].as_h
    diff["before"].as_h.keys.must_equal(["path"])
    diff["after"].as_h.keys.must_equal(["path"])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "diffs a chattr flag change with the raw requested value" do
    # attributes: goes through basic.py's set_attributes_if_different, which
    # records the current lsattr flags against the RAW requested value -
    # operator included ("+i", not the resolved "i"). Skipped on filesystems
    # without chattr support (tmpfs).
    dir = PluginSpecHelper.tmp_path("copy-attr-diff-chattr")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "dest.txt")
    File.write(dest, "hello")

    probe = PluginSpecHelper.run("copy", {
      "content"       => "hello",
      "dest"          => dest,
      "attributes"    => "+a",
      "_ansible_diff" => "true",
    })
    skip "chattr unsupported here" if probe["failed"]?.try(&.as_bool)

    probe["changed"].as_bool.must_equal(true)
    diff = probe["diff"].as_h
    diff["after"]["attributes"].as_s.must_equal("+a")
  ensure
    if dest && File.exists?(dest)
      PluginSpecHelper.run("copy", {"content" => "hello", "dest" => dest, "attributes" => "-a"})
      File.delete(dest)
    end
  end

  it "diffs a mode fix on template's equal-content path" do
    dir = PluginSpecHelper.tmp_path("template-attr-diff-mode")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "dest.txt")
    File.write(dest, "hello\n")
    File.chmod(dest, 0o644)

    result = PluginSpecHelper.run("template", {
      "content"                 => "hello\n",
      "dest"                    => dest,
      "mode"                    => "0600",
      "_rendered_from_template" => dest,
      "_ansible_diff"           => "true",
    })

    result["changed"].as_bool.must_equal(true)
    diff = result["diff"].as_h
    diff["before"].as_h.keys.sort!.must_equal(["mode", "path"])
    diff["before"]["mode"].as_s.must_equal("0644")
    diff["after"]["mode"].as_s.must_equal("0600")
    diff["before"]["path"].as_s.must_equal(dest)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
