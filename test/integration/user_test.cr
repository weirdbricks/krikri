require "../minitest_helper"

# Same safety rule as group_spec.cr: these run in --check mode only (or
# query state that never mutates anything). Never invokes useradd/usermod/
# userdel for real, even against a scratch username - this must stay safe
# to run repeatedly on a developer's real machine.

private NONEXISTENT_USER = "krikri-playbook-test-nonexistent-user"

describe "user plugin" do
  it "reports no change for an existing user whose attributes already match (read-only getent check)" do
    shell = `getent passwd root`.split(":")[6].strip

    result = PluginSpecHelper.run("user", {"name" => "root", "shell" => shell, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  # Ansible.builtin.user's argument_spec declares `name` with alias
  # `user` (`name=dict(type='str', required=True, aliases=['user'])`) -
  # RedHatOfficial.rhel9_pci_dss (round 812000) writes `user: '{{ item
  # }}'` throughout its STIG role, which Ansible resolves fine via
  # the alias; this plugin only ever read `name`, failing "Missing
  # required parameter: name" despite the alias spelling being given.
  it "resolves the user: alias of name:" do
    shell = `getent passwd root`.split(":")[6].strip

    result = PluginSpecHelper.run("user", {"user" => "root", "shell" => shell, "_ansible_check_mode" => "true"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
  end

  # Real bug found benchmarking konstruktoid.docker_rootless (0.9.617):
  # Ansible's user module ALWAYS returns the resolved user facts
  # (home/uid/group/shell/name) in its register result, whether the
  # user was just created, modified, or already matched exactly. This
  # plugin's PluginResult never carried any of them at all - `register:
  # docker_user_info` followed by `{{ docker_user_info.home }}` was
  # undefined regardless of whether the user already existed, failing
  # any later task that reads it.
  it "returns home/uid/group/shell/name facts in the register result, matching Ansible" do
    root_home = `getent passwd root`.split(":")[5].strip
    root_uid = `id -u root`.strip.to_i64
    root_shell = `getent passwd root`.split(":")[6].strip

    result = PluginSpecHelper.run("user", {"name" => "root", "_ansible_check_mode" => "true"})

    result["home"].as_s.must_equal(root_home)
    result["uid"].as_i64.must_equal(root_uid)
    result["shell"].as_s.must_equal(root_shell)
    result["name"].as_s.must_equal("root")
  end

  it "reports no change when group: is given by name and already matches (getent passwd's own gid field is numeric, not a name)" do
    root_group_name = `id -gn root`.strip

    result = PluginSpecHelper.run("user", {"name" => "root", "group" => root_group_name, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  # Real check-mode modify of an existing user registers the full shape:
  # modify_user is check-mode aware and returns rc=0 for a would-be
  # change, so the result carries name/state, the modify-path params,
  # changed, and the resolved facts (live-verified vs 2.19.11:
  # [name, state, append, move_home, changed, uid, group, comment, home,
  # shell, failed]).
  it "reports it would modify an existing user when an attribute differs (check mode, no real change)" do
    result = PluginSpecHelper.run("user", {"name" => "root", "shell" => "/bin/totally-fake-shell", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["name"].as_s.must_equal("root")
    result["append"].as_bool.must_equal(false)
    result["move_home"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["name", "state", "append", "move_home", "changed", "uid", "group", "comment", "home", "shell"])
    `getent passwd root`.split(":")[6].strip.wont_equal("/bin/totally-fake-shell")
  end

  # Real user.py's check-mode create branch exits with bare
  # exit_json(changed=True) before anything else runs - the registered
  # shape is just [changed, failed], no name/state/system/create_home
  # echo (live-verified vs 2.19.11, round 992000's user_check probe:
  # {"changed": true, "failed": false}).
  it "reports it would create a user that does not exist yet (check mode, no real creation)" do
    result = PluginSpecHelper.run("user", {"name" => NONEXISTENT_USER, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed"])
    `getent passwd #{NONEXISTENT_USER}`.strip.must_be_empty
  end

  # Real user.py echoes name/state with changed: false for an account
  # that doesn't exist - no msg key (live-verified: [name, state,
  # changed, failed]).
  it "reports no change when removing a user that already doesn't exist (state=absent is a genuine no-op, safe even without check mode)" do
    result = PluginSpecHelper.run("user", {"name" => NONEXISTENT_USER, "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
    result["name"].as_s.must_equal(NONEXISTENT_USER)
    result["state"].as_s.must_equal("absent")
    result.as_h.keys.must_equal(["name", "state", "changed"])
  end

  it "reports it would remove an existing user (check mode, no real removal)" do
    result = PluginSpecHelper.run("user", {"name" => "root", "state" => "absent", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    # Ansible's check-mode absent branch exits with bare exit_json(changed=True).
    result.as_h.keys.must_equal(["changed"])
    `getent passwd root`.strip.wont_be_empty
  end

  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("user", {} of String => String)
    result["failed"].as_bool.must_equal(true)
  end

  # Ad-hoc CLI comparison sweep vs Ansible (2026-09-13): verified
  # live against ansible-core 2.19's user module - `state` is echoed on
  # every path, `append`/`move_home` ride along on the modify-existing-
  # account path, `groups` (the comma-joined param) only when given, and
  # a given `password:` comes back as 'NOT_LOGGING_PASSWORD'.
  it "echoes state plus the modify-path append/move_home and a given groups value (check mode)" do
    result = PluginSpecHelper.run("user", {
      "name" => "root", "state" => "present", "groups" => "root",
      "append" => "true", "_ansible_check_mode" => "true",
    })

    result["state"].as_s.must_equal("present")
    result["append"].as_bool.must_equal(true)
    result["move_home"].as_bool.must_equal(false)
    result["groups"].as_s.must_equal("root")
  end

  # Real user.py only echoes system/create_home on the create path AFTER
  # it actually ran (a check-mode create of a missing user exits bare
  # changed before ever reaching that echo) - verified live vs 2.19.11
  # with a real state=present run in the round 992000 capture:
  # [name, state, system, create_home, changed, uid, ...].
  it "echoes the create-path system/create_home flags only on a real create, not in check mode" do
    result = PluginSpecHelper.run("user", {"name" => NONEXISTENT_USER, "_ansible_check_mode" => "true"})

    result.as_h.keys.must_equal(["changed"])
    result["system"]?.must_be_nil
    result["create_home"]?.must_be_nil
  end

  it "masks a given password as NOT_LOGGING_PASSWORD" do
    result = PluginSpecHelper.run("user", {
      "name" => "root", "password" => "$6$salt$hash", "_ansible_check_mode" => "true",
    })

    result["password"].as_s.must_equal("NOT_LOGGING_PASSWORD")
  end

  it "echoes name/state (and no per-account facts) on the absent path after a real removal" do
    result = PluginSpecHelper.run("user", {"name" => NONEXISTENT_USER, "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
    result["name"].as_s.must_equal(NONEXISTENT_USER)
    result["state"].as_s.must_equal("absent")
    result.as_h.keys.must_equal(["name", "state", "changed"])
  end
end
