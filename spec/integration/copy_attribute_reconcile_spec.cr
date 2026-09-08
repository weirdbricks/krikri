require "../spec_helper"

describe "copy plugin - identical-content attribute reconciliation" do
  it "reports changed when identical content needs a mode fix (content: path)" do
    # The identical-content early return used to apply mode/owner/group
    # reconciliation (apply_file_attributes) but hardcode changed: false,
    # so anything that re-broke an attribute between copy runs - the role
    # shape from bitintheskud.ansible-role-ecs-agent: file: recurse:
    # immediately followed by copy: on a file inside that tree - made
    # copy: silently report ok forever while fixing the mode on disk
    # every run. Real Ansible reports `changed` once (live-verified
    # against ansible-core 2.19), then ok.
    dest = File.tempname("copy-reconcile")
    File.write(dest, "hello")
    File.chmod(dest, 0o755)

    result = PluginSpecHelper.run("copy", {"content" => "hello", "dest" => dest, "mode" => "0640"})
    result["changed"].as_bool.should be_true
    info = File.info(dest)
    info.permissions.value.to_s(8).should eq("640")

    rerun = PluginSpecHelper.run("copy", {"content" => "hello", "dest" => dest, "mode" => "0640"})
    rerun["changed"].as_bool.should be_false
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reports changed when identical content needs a mode fix (src: path)" do
    src = File.tempname("copy-reconcile-src")
    dest = File.tempname("copy-reconcile-dest")
    File.write(src, "hello")
    File.write(dest, "hello")
    File.chmod(dest, 0o755)

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest, "mode" => "0640"})
    result["changed"].as_bool.should be_true

    rerun = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest, "mode" => "0640"})
    rerun["changed"].as_bool.should be_false
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reports changed for the copy task that follows a file: recurse: mode fix (the ecs-agent warm sequence)" do
    # The original loose end: file: recurse: (mode 0755) on a directory
    # whose top-level attributes already match, immediately followed by
    # copy: (mode 0640) on a file inside it. The file task fixes the
    # nested file to 0755; the copy task must then restore 0640 AND
    # report changed - it used to report ok while fixing it.
    dir = File.join(Dir.tempdir, "copy-reconcile-dir-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    File.chmod(dir, 0o755)
    nested = File.join(dir, "ecs.env")
    File.write(nested, "A=B")
    File.chmod(nested, 0o640)

    file_result = PluginSpecHelper.run("file", {"path" => dir, "state" => "directory", "mode" => "0755", "recurse" => "yes"})
    file_result["changed"].as_bool.should be_true

    copy_result = PluginSpecHelper.run("copy", {"content" => "A=B", "dest" => nested, "mode" => "0640"})
    copy_result["changed"].as_bool.should be_true
    nested_info = File.info(nested)
    nested_info.permissions.value.to_s(8).should eq("640")
  ensure
    Process.run("rm", ["-rf", dir]) if dir && Dir.exists?(dir)
  end
end
