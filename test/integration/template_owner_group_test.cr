require "../minitest_helper"
require "digest/sha1"

# Regression spec for template: ownership application (gokev.motd-splash
# round 5210000): the template plugin's apply_file_attributes shelled out
# to chown/chgrp with stdout, stderr AND the exit status all discarded,
# so a template task whose group: named a nonexistent group silently
# reported changed where real ansible fails the task ("chgrp failed:
# failed to look up group wheel" - ansible's basic.py). The template
# path now goes through BasePlugin#apply_owner_group_mode, which
# resolves the name first and raises Ansible's own text (the copy/file
# plugins already did this - only template: was still shelling blind).
describe "template plugin - owner/group" do
  it "fails with Ansible's exact message when group: names a nonexistent group" do
    dest = File.tempname("template-bad-group-spec")

    result = PluginSpecHelper.run("template", {
      "content" => "splash\n",
      "dest"    => dest,
      "group"   => "no-such-group-krikri-spec",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("chgrp failed: failed to look up group no-such-group-krikri-spec")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  # Real's copy-module fail_json on the chgrp/chown lookup failure carries
  # the rendered content's sha1 and the add_path_info stat block for dest,
  # with no dest/src keys (live-verified vs ansible 2.19, issue #514).
  it "carries checksum, path and the stat block on the fresh-write group failure" do
    dest = File.tempname("template-bad-group-fields")

    result = PluginSpecHelper.run("template", {
      "content" => "splash\n",
      "dest"    => dest,
      "group"   => "no-such-group-krikri-spec",
    })

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("chgrp failed: failed to look up group no-such-group-krikri-spec")
    result["checksum"].as_s.must_equal(Digest::SHA1.hexdigest("splash\n"))
    result["path"].as_s.must_equal(dest)
    result["uid"].as_i64.wont_be_nil
    result["gid"].as_i64.wont_be_nil
    result["owner"].as_s.wont_be_nil
    result["group"].as_s.wont_be_nil
    result["mode"].as_s.wont_be_nil
    result["state"].as_s.must_equal("file")
    result["size"].as_i64.must_equal("splash\n".bytesize)
    result.as_h.keys.first(11).must_equal(%w[changed checksum gid group mode msg owner path size state uid])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  # The identical-content rerun path applies attributes without writing,
  # and fails with the same copy-module result shape there (issue #514).
  it "carries the same failure shape on the identical-content rerun branch" do
    dest = File.tempname("template-bad-group-equal")
    PluginSpecHelper.run("template", {"content" => "splash\n", "dest" => dest})

    result = PluginSpecHelper.run("template", {
      "content" => "splash\n",
      "dest"    => dest,
      "group"   => "no-such-group-krikri-spec",
    })

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("chgrp failed: failed to look up group no-such-group-krikri-spec")
    result["checksum"].as_s.must_equal(Digest::SHA1.hexdigest("splash\n"))
    result["path"].as_s.must_equal(dest)
    result["uid"].as_i64.wont_be_nil
    result["gid"].as_i64.wont_be_nil
    result["owner"].as_s.wont_be_nil
    result["group"].as_s.wont_be_nil
    result["mode"].as_s.wont_be_nil
    result["state"].as_s.must_equal("file")
    result["size"].as_i64.must_equal("splash\n".bytesize)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  # Issue #1678 (gokev.motd-splash, check phase): on an equal-content dest
  # copy's action plugin hands the task to the FILE module, whose
  # set_group_if_different still resolves the name in check mode and fails
  # the task - plus file.py's own "Create group up to this point in real
  # play" warning. Live-verified against ansible-core 2.21.6, which also
  # carries the dest's stat block and the action's checksum on the failure.
  it "fails an unknown group on the equal-content check-mode branch" do
    dest = File.tempname("template-check-bad-group")
    PluginSpecHelper.run("template", {"content" => "splash\n", "dest" => dest})

    result = PluginSpecHelper.run("template", {
      "content"             => "splash\n",
      "dest"                => dest,
      "group"               => "no-such-group-krikri-spec",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(false)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("chgrp failed: failed to look up group no-such-group-krikri-spec")
    result["checksum"].as_s.must_equal(Digest::SHA1.hexdigest("splash\n"))
    result["path"].as_s.must_equal(dest)
    result["state"].as_s.must_equal("file")
    result["size"].as_i64.must_equal("splash\n".bytesize)
    result["warnings"].as_a.map(&.as_s).must_equal([
      "failed to look up group no-such-group-krikri-spec. Create group up to this point in real play",
    ])
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  # The same file-module call reports a stale attribute as `changed` in
  # check mode without writing it - krikri answered ok, so a role that
  # relies on --check to surface drift saw nothing (live-verified vs
  # ansible-core 2.21.6: changed, dest, path, checksum, stat block).
  it "reports a stale attribute as changed in check mode without writing it" do
    dest = File.tempname("template-check-attr-drift")
    PluginSpecHelper.run("template", {"content" => "splash\n", "dest" => dest})
    File.chmod(dest, 0o600)

    result = PluginSpecHelper.run("template", {
      "content"             => "splash\n",
      "dest"                => dest,
      "mode"                => "0644",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    expect(result["failed"]?.try(&.as_bool)).wont_equal(true)
    result["checksum"].as_s.must_equal(Digest::SHA1.hexdigest("splash\n"))
    result["dest"].as_s.must_equal(dest)
    result["path"].as_s.must_equal(dest)
    File.info(dest).permissions.value.to_s(8).must_equal("600")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
