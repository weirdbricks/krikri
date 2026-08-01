require "../spec_helper"

# These specs deliberately run ONLY in --check mode (or query state that
# never mutates anything, like a lookup on a nonexistent group). They must
# be safe to run repeatedly on a developer's real machine, not just in a
# throwaway CI container - so this file never actually invokes groupadd/
# groupmod/groupdel for real, even against a scratch group name.

private NONEXISTENT_GROUP = "crystal-ansible-test-nonexistent-group"

describe "group plugin" do
  it "reports no change for an existing group whose gid already matches (read-only getent check)" do
    root_gid = `getent group root`.split(":")[2].strip

    result = PluginSpecHelper.run("group", {"name" => "root", "gid" => root_gid, "check_mode" => "true"})

    result["changed"].as_bool.should be_false
    result["failed"]?.try(&.as_bool).should be_falsey
  end

  it "reports it would modify an existing group when the gid differs (check mode, no real change)" do
    result = PluginSpecHelper.run("group", {"name" => "root", "gid" => "999999", "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    result["msg"].as_s.should contain("check mode")
    `getent group root`.split(":")[2].strip.should_not eq("999999")
  end

  it "reports it would create a group that does not exist yet (check mode, no real creation)" do
    result = PluginSpecHelper.run("group", {"name" => NONEXISTENT_GROUP, "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    result["msg"].as_s.should contain("check mode")
    `getent group #{NONEXISTENT_GROUP}`.strip.should be_empty
  end

  it "reports no change when removing a group that already doesn't exist (state=absent is a genuine no-op, safe even without check mode)" do
    result = PluginSpecHelper.run("group", {"name" => NONEXISTENT_GROUP, "state" => "absent"})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("already absent")
  end

  it "reports it would remove an existing group (check mode, no real removal)" do
    result = PluginSpecHelper.run("group", {"name" => "root", "state" => "absent", "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    `getent group root`.strip.should_not be_empty
  end

  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("group", {} of String => String)
    result["failed"].as_bool.should be_true
  end
end
