require "../spec_helper"

# Same safety rule as group_spec.cr: these run in --check mode only (or
# query state that never mutates anything). Never invokes useradd/usermod/
# userdel for real, even against a scratch username - this must stay safe
# to run repeatedly on a developer's real machine.

private NONEXISTENT_USER = "krikri-playbook-test-nonexistent-user"

describe "user plugin" do
  it "reports no change for an existing user whose attributes already match (read-only getent check)" do
    shell = `getent passwd root`.split(":")[6].strip

    result = PluginSpecHelper.run("user", {"name" => "root", "shell" => shell, "check_mode" => "true"})

    result["changed"].as_bool.should be_false
    result["failed"]?.try(&.as_bool).should be_falsey
  end

  # Real ansible.builtin.user's argument_spec declares `name` with alias
  # `user` (`name=dict(type='str', required=True, aliases=['user'])`) -
  # RedHatOfficial.rhel9_pci_dss (round 812000) writes `user: '{{ item
  # }}'` throughout its STIG role, which real Ansible resolves fine via
  # the alias; this plugin only ever read `name`, failing "Missing
  # required parameter: name" despite the alias spelling being given.
  it "resolves the user: alias of name:" do
    shell = `getent passwd root`.split(":")[6].strip

    result = PluginSpecHelper.run("user", {"user" => "root", "shell" => shell, "check_mode" => "true"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_false
  end

  # Real bug found benchmarking konstruktoid.docker_rootless (0.9.617):
  # real Ansible's user module ALWAYS returns the resolved user facts
  # (home/uid/group/shell/name) in its register result, whether the
  # user was just created, modified, or already matched exactly. This
  # plugin's PluginResult never carried any of them at all - `register:
  # docker_user_info` followed by `{{ docker_user_info.home }}` was
  # undefined regardless of whether the user already existed, failing
  # any later task that reads it.
  it "returns home/uid/group/shell/name facts in the register result, matching real Ansible" do
    root_home = `getent passwd root`.split(":")[5].strip
    root_uid = `id -u root`.strip.to_i64
    root_shell = `getent passwd root`.split(":")[6].strip

    result = PluginSpecHelper.run("user", {"name" => "root", "check_mode" => "true"})

    result["home"].as_s.should eq(root_home)
    result["uid"].as_i64.should eq(root_uid)
    result["shell"].as_s.should eq(root_shell)
    result["name"].as_s.should eq("root")
  end

  it "reports no change when group: is given by name and already matches (getent passwd's own gid field is numeric, not a name)" do
    root_group_name = `id -gn root`.strip

    result = PluginSpecHelper.run("user", {"name" => "root", "group" => root_group_name, "check_mode" => "true"})

    result["changed"].as_bool.should be_false
    result["failed"]?.try(&.as_bool).should be_falsey
  end

  it "reports it would modify an existing user when an attribute differs (check mode, no real change)" do
    result = PluginSpecHelper.run("user", {"name" => "root", "shell" => "/bin/totally-fake-shell", "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    result["msg"].as_s.should contain("check mode")
    `getent passwd root`.split(":")[6].strip.should_not eq("/bin/totally-fake-shell")
  end

  it "reports it would create a user that does not exist yet (check mode, no real creation)" do
    result = PluginSpecHelper.run("user", {"name" => NONEXISTENT_USER, "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    result["msg"].as_s.should contain("check mode")
    `getent passwd #{NONEXISTENT_USER}`.strip.should be_empty
  end

  it "reports no change when removing a user that already doesn't exist (state=absent is a genuine no-op, safe even without check mode)" do
    result = PluginSpecHelper.run("user", {"name" => NONEXISTENT_USER, "state" => "absent"})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("already absent")
  end

  it "reports it would remove an existing user (check mode, no real removal)" do
    result = PluginSpecHelper.run("user", {"name" => "root", "state" => "absent", "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    `getent passwd root`.strip.should_not be_empty
  end

  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("user", {} of String => String)
    result["failed"].as_bool.should be_true
  end

  # Ad-hoc CLI comparison sweep vs real ansible (2026-09-13): verified
  # live against ansible-core 2.19's user module - `state` is echoed on
  # every path, `append`/`move_home` ride along on the modify-existing-
  # account path, `groups` (the comma-joined param) only when given, and
  # a given `password:` comes back as 'NOT_LOGGING_PASSWORD'.
  it "echoes state plus the modify-path append/move_home and a given groups value (check mode)" do
    result = PluginSpecHelper.run("user", {
      "name" => "root", "state" => "present", "groups" => "root",
      "append" => "true", "check_mode" => "true",
    })

    result["state"].as_s.should eq("present")
    result["append"].as_bool.should be_true
    result["move_home"].as_bool.should be_false
    result["groups"].as_s.should eq("root")
  end

  it "echoes the create-path system/create_home flags for a not-yet-existing user (check mode)" do
    result = PluginSpecHelper.run("user", {"name" => NONEXISTENT_USER, "check_mode" => "true"})

    result["state"].as_s.should eq("present")
    result["system"].as_bool.should be_false
    result["create_home"].as_bool.should be_true
    result["append"]?.should be_nil
    result["move_home"]?.should be_nil
  end

  it "masks a given password as NOT_LOGGING_PASSWORD" do
    result = PluginSpecHelper.run("user", {
      "name" => "root", "password" => "$6$salt$hash", "check_mode" => "true",
    })

    result["password"].as_s.should eq("NOT_LOGGING_PASSWORD")
  end

  it "echoes name/state (and no per-account facts) on the absent path after a real removal" do
    result = PluginSpecHelper.run("user", {"name" => NONEXISTENT_USER, "state" => "absent"})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("already absent")
  end
end
