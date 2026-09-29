require "../minitest_helper"

# These specs deliberately run ONLY in --check mode (or query state that
# never mutates anything, like a lookup on a nonexistent group). They must
# be safe to run repeatedly on a developer's real machine, not just in a
# throwaway CI container - so this file never actually invokes groupadd/
# groupmod/groupdel for real, even against a scratch group name.

private NONEXISTENT_GROUP = "krikri-playbook-test-nonexistent-group"

describe "group plugin" do
  it "reports no change for an existing group whose gid already matches (read-only getent check)" do
    root_gid = `getent group root`.split(":")[2].strip

    result = PluginSpecHelper.run("group", {"name" => "root", "gid" => root_gid, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "reports it would modify an existing group when the gid differs (check mode, no real change)" do
    result = PluginSpecHelper.run("group", {"name" => "root", "gid" => "999999", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("check mode")
    `getent group root`.split(":")[2].strip.wont_equal("999999")
  end

  it "reports it would create a group that does not exist yet (check mode, no real creation)" do
    result = PluginSpecHelper.run("group", {"name" => NONEXISTENT_GROUP, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("check mode")
    `getent group #{NONEXISTENT_GROUP}`.strip.must_be_empty
  end

  it "reports no change when removing a group that already doesn't exist (state=absent is a genuine no-op, safe even without check mode)" do
    result = PluginSpecHelper.run("group", {"name" => NONEXISTENT_GROUP, "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_include("already absent")
  end

  it "reports it would remove an existing group (check mode, no real removal)" do
    result = PluginSpecHelper.run("group", {"name" => "root", "state" => "absent", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    `getent group root`.strip.wont_be_empty
  end

  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("group", {} of String => String)
    result["failed"].as_bool.must_equal(true)
  end

  # Real group.py's create/modify/delete failures are all
  # fail_json(name=group.name, msg=err) - msg is the RAW groupadd
  # stderr (trailing newline included), plus the name echo, with no
  # "Failed to <action>: " prefix (live-verified vs 2.19.11 as root:
  # fatal => {"changed": false, "msg": "groupadd: Invalid
  # configuration: GID_MIN (1000), GID_MAX (86)\n", "name": ...}).
  # Deliberately triggers groupadd for real, but it can never mutate:
  # GID_MAX=86 < GID_MIN makes the creation fail as root ("Invalid
  # configuration"), and non-root fails even earlier ("Permission
  # denied") - either way the group is not created.
  it "fails groupadd with raw stderr as msg plus the name echo - no 'Failed to' prefix" do
    result = PluginSpecHelper.run("group", {"name" => NONEXISTENT_GROUP, "gid_max" => "86"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.starts_with?("Failed to").must_equal(false)
    result["msg"].as_s.must_include("groupadd:")
    result["msg"].as_s.ends_with?("\n").must_equal(true)
    result["name"].as_s.must_equal(NONEXISTENT_GROUP)
    result.as_h.has_key?("state").must_equal(false)
  end
end
