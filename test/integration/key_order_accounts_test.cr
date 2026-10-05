require "../minitest_helper"

require "json"

# Registered-result key order (and value shapes) for the user/group/
# authorized_key/known_hosts plugins, pinned to what REAL ansible-core
# 2.19.11 (+ ansible.posix 2.2.2) registers - each shape observed through
# `{{ r | to_json }}` on a registered task, once in krikri-role-tester
# round 992000 against a real Ubuntu 22.04 Atlantic host and once replayed
# probe-by-probe in a local root podman ubuntu:22.04 container (the -v
# dump sorts alphabetically, so order is only observable programmatically).
#
# Everything below runs ROOT-FREE (check mode, absent-no-op paths, tmp
# paths, or failures that happen before any mutation). The shapes that
# need real useradd/groupadd mutation (create/modify/remove success) are
# pinned by the round 992000 capture and the container replay instead,
# and noted in comments where relevant.
#
# The params-echo modules (authorized_key, known_hosts) follow Ansible's
# echo rule: explicitly-passed params alphabetically (the controller
# sorts the module-args handoff), then not-passed params in a fixed
# per-module order - verified live against four different explicit-param
# subsets per module.

# Runs the known_hosts plugin against a scratch file and returns the raw
# wire result. mode: 0600 is what the plugin itself must NOT impose (real
# creates 0644 via umask), so the stat-block assertions below check key
# presence/type, not the exact mode of a fresh file.
private def known_hosts(params : Hash(String, String)) : JSON::Any
  PluginSpecHelper.run("known_hosts", params)
end

describe "known_hosts plugin result key order" do
  it "serializes a fresh add as params-echo + changed + diff + the stat block" do
    path = PluginSpecHelper.tmp_path("kh-order-add")
    File.delete(path) if File.exists?(path)

    result = known_hosts({
      "name"  => "example.com",
      "key"   => "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX",
      "state" => "present",
      "path"  => path,
    })

    result["changed"].as_bool.must_equal(true)
    result["state"].as_s.must_equal("file")
    result["name"].as_s.must_equal("example.com")
    result["hash_host"].as_bool.must_equal(false)
    result["diff"]["before_header"].as_s.must_equal("/dev/null")
    result["diff"]["after"].as_s.must_equal("example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX\n")
    result["uid"].as_i?.wont_be_nil
    result["mode"].as_s.must_match(/\A0[0-7]{3,4}\z/)
    result.as_h.keys.must_equal([
      "key", "name", "path", "state", "hash_host", "changed", "diff",
      "uid", "gid", "owner", "group", "mode", "size",
    ])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes an already-present rerun identically, with before == after in the diff" do
    path = PluginSpecHelper.tmp_path("kh-order-exists")
    File.delete(path) if File.exists?(path)
    key = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX"
    known_hosts({"name" => "example.com", "key" => key, "state" => "present", "path" => path})

    result = known_hosts({"name" => "example.com", "key" => key, "state" => "present", "path" => path})

    result["changed"].as_bool.must_equal(false)
    result["diff"]["before"].as_s.must_equal(result["diff"]["after"].as_s)
    result.as_h.keys.must_equal([
      "key", "name", "path", "state", "hash_host", "changed", "diff",
      "uid", "gid", "owner", "group", "mode", "size",
    ])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a replacement with the old line in before and the new one in after" do
    path = PluginSpecHelper.tmp_path("kh-order-replace")
    File.delete(path) if File.exists?(path)
    key1 = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX"
    key2 = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDifferentKeyDataYYYYYYYYYYYYYYYYYY"
    known_hosts({"name" => "example.com", "key" => key1, "state" => "present", "path" => path})

    result = known_hosts({"name" => "example.com", "key" => key2, "state" => "present", "path" => path})

    result["changed"].as_bool.must_equal(true)
    result["diff"]["before"].as_s.must_include("ExampleKeyData")
    result["diff"]["after"].as_s.must_include("DifferentKeyData")
    result["diff"]["after"].as_s.wont_include("ExampleKeyData")
    result.as_h.keys.must_equal([
      "key", "name", "path", "state", "hash_host", "changed", "diff",
      "uid", "gid", "owner", "group", "mode", "size",
    ])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a removal with an empty after and keeps the stat block" do
    path = PluginSpecHelper.tmp_path("kh-order-remove")
    File.delete(path) if File.exists?(path)
    key = "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX"
    known_hosts({"name" => "example.com", "key" => key, "state" => "present", "path" => path})

    result = known_hosts({"name" => "example.com", "key" => key, "state" => "absent", "path" => path})

    result["changed"].as_bool.must_equal(true)
    result["diff"]["after"].as_s.must_equal("")
    result["size"].as_i.must_equal(0)
    result.as_h.keys.must_equal([
      "key", "name", "path", "state", "hash_host", "changed", "diff",
      "uid", "gid", "owner", "group", "mode", "size",
    ])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a no-match removal as the full echo shape with changed: false (Ansible's early return, not the bare one)" do
    path = PluginSpecHelper.tmp_path("kh-order-absent-again")
    File.delete(path) if File.exists?(path)

    result = known_hosts({
      "name"  => "example.com",
      "key"   => "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX",
      "state" => "absent",
      "path"  => path,
    })

    result["changed"].as_bool.must_equal(false)
    # The path doesn't exist here, so add_path_info adds no stat block and
    # the echoed state stays the original param (real: same - its early
    # return still merges with main()'s params echo, but only an EXISTING
    # path gets the uid/gid/... block and the state -> "file" overwrite).
    result.as_h.keys.must_equal(["key", "name", "path", "state", "hash_host", "changed", "diff"])
    result["state"].as_s.must_equal("absent")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  # Ansible's check-mode path exits INSIDE enforce_state with
  # exit_json(changed=, diff=) - no params echo, no stat block
  # (round 992000's known_hosts_check: [changed, diff, failed]).
  it "serializes a check-mode add as just changed + diff" do
    path = PluginSpecHelper.tmp_path("kh-order-check")
    File.delete(path) if File.exists?(path)

    result = known_hosts({
      "name"                => "example.com",
      "key"                 => "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX",
      "state"               => "present",
      "path"                => path,
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["diff"]["before_header"].as_s.must_equal("/dev/null")
    result.as_h.keys.must_equal(["changed", "diff"])
    File.exists?(path).must_equal(false)
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes a whole-host removal (no key) without stat keys when the file is missing, key echoed as null" do
    path = PluginSpecHelper.tmp_path("kh-order-nokey")
    File.delete(path) if File.exists?(path)

    result = known_hosts({"name" => "example.com", "state" => "absent", "path" => path})

    result["changed"].as_bool.must_equal(false)
    result["key"]?.try(&.as_s?).must_be_nil
    result.as_h.keys.must_equal(["name", "path", "state", "hash_host", "key", "changed", "diff"])
    result["state"].as_s.must_equal("absent")
    result["diff"]["before_header"].as_s.must_equal("/dev/null")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "puts explicitly-passed params first (alphabetically) with the hashed line in the diff when hash_host: is given" do
    path = PluginSpecHelper.tmp_path("kh-order-hash")
    File.delete(path) if File.exists?(path)

    result = known_hosts({
      "name"      => "example.com",
      "key"       => "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHereXXXXXXXXXXXXXXXX",
      "state"     => "present",
      "path"      => path,
      "hash_host" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["diff"]["after"].as_s.must_match(/\A\|1\|[^\s]+ ssh-ed25519 /)
    result.as_h.keys.must_equal([
      "hash_host", "key", "name", "path", "state", "changed", "diff",
      "uid", "gid", "owner", "group", "mode", "size",
    ])
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end

describe "authorized_key plugin result key order" do
  it "serializes an add via path: as params-echo (explicit params alphabetically) + keyfile + changed + the stat block" do
    base = PluginSpecHelper.tmp_path("ak-order-add")
    `rm -rf #{base} && mkdir -p #{base}`
    path = File.join(base, "authorized_keys")

    # manage_dir: false keeps this root-free - Ansible's manage_dir branch
    # chowns the parent dir to the user (root here), which fails EPERM
    # for a non-root caller exactly like Ansible does.
    result = PluginSpecHelper.run("authorized_key", {
      "user"       => "root",
      "key"        => "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC testkey@x comment",
      "path"       => path,
      "manage_dir" => "false",
    })

    result["changed"].as_bool.must_equal(true)
    result["keyfile"].as_s.must_equal(path)
    result["state"].as_s.must_equal("file")
    result.as_h.keys.must_equal([
      "key", "manage_dir", "path", "user", "state", "exclusive",
      "validate_certs", "follow", "key_options", "comment", "keyfile",
      "changed", "uid", "gid", "owner", "group", "mode", "size",
    ])
  ensure
    `rm -rf #{base}` if base
  end

  it "serializes an idempotent rerun with NO changed key (the executor backfills failed-then-changed, Ansible's [..., keyfile, failed, changed] shape)" do
    base = PluginSpecHelper.tmp_path("ak-order-exists")
    `rm -rf #{base} && mkdir -p #{base}`
    path = File.join(base, "authorized_keys")
    key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC testkey@x comment"
    File.write(path, "#{key}\n")
    PluginSpecHelper.run("authorized_key", {"user" => "root", "key" => key, "path" => path, "manage_dir" => "false"})

    result = PluginSpecHelper.run("authorized_key", {"user" => "root", "key" => key, "path" => path, "manage_dir" => "false"})

    result.as_h.has_key?("changed").must_equal(false)
    result.as_h.keys.must_equal([
      "key", "manage_dir", "path", "user", "state", "exclusive",
      "validate_certs", "follow", "key_options", "comment", "keyfile",
      "uid", "gid", "owner", "group", "mode", "size",
    ])
  ensure
    `rm -rf #{base}` if base
  end

  # The round 992000 probe shape (user+key+state given, no path): the
  # check-mode read of root's own authorized_keys never writes anything,
  # so this stays root-free.
  it "serializes a check-mode add with the probe's echo order and changed, no stat block" do
    result = PluginSpecHelper.run("authorized_key", {
      "user"                => "root",
      "key"                 => "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC probe2@x comment",
      "state"               => "present",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["path"]?.try(&.as_s?).must_be_nil
    result.as_h.keys.must_equal([
      "key", "state", "user", "manage_dir", "exclusive", "validate_certs",
      "follow", "path", "key_options", "comment", "keyfile", "changed",
    ])
  end

  it "fails a garbage key with Ansible's plain fail shape [failed, msg, changed, exception]" do
    result = PluginSpecHelper.run("authorized_key", {
      "user" => "root", "key" => "not-a-real-ssh-key", "state" => "present",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("invalid key specified: not-a-real-ssh-key")
    result.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
  end
end

describe "user plugin result key order" do
  # Real user.py's check-mode create branch exits with bare
  # exit_json(changed=True) - nothing else (round 992000's user_check).
  it "serializes a check-mode create of a missing user as just [changed]" do
    result = PluginSpecHelper.run("user", {
      "name" => "krikri-kop-nobody", "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed"])
  end

  # Real check-mode modify of an existing user registers the full shape
  # (modify_user is check-mode aware, rc=0 for a would-be change).
  it "serializes a check-mode modify of an existing user as the full modify shape" do
    result = PluginSpecHelper.run("user", {
      "name" => "root", "shell" => "/bin/krikri-fake-shell", "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["name", "state", "append", "move_home", "changed", "uid", "group", "comment", "home", "shell"])
  end

  it "serializes a check-mode no-op modify identically (changed: false)" do
    shell = `getent passwd root`.split(":")[6].strip
    result = PluginSpecHelper.run("user", {
      "name" => "root", "shell" => shell, "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["name", "state", "append", "move_home", "changed", "uid", "group", "comment", "home", "shell"])
  end

  it "serializes an absent no-op as [name, state, changed]" do
    result = PluginSpecHelper.run("user", {
      "name" => "krikri-kop-nobody", "state" => "absent",
    })

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["name", "state", "changed"])
  end

  it "serializes a check-mode removal of an existing user as just [changed]" do
    result = PluginSpecHelper.run("user", {
      "name" => "root", "state" => "absent", "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed"])
  end

  # Real checks a given group: BEFORE useradd and fails with a plain
  # fail_json - no name/rc echo (round 992000's user_fail: [failed, msg,
  # changed, exception], msg "Group kop_nosuchgroup does not exist").
  it "fails a nonexistent group: with the plain fail shape and Ansible's message" do
    result = PluginSpecHelper.run("user", {
      "name" => "krikri-kop-nobody", "group" => "krikri-kop-nosuchgroup",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Group krikri-kop-nosuchgroup does not exist")
    result.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
  end

  # A create that useradd itself rejects (uid 0 is taken) exercises the
  # fail_json(name=, msg=err, rc=rc) shape: the registered order puts the
  # kwargs first (name, rc), then failed, msg, changed, exception
  # (live-verified vs 2.19.11: [name, rc, failed, msg, changed,
  # exception]). Safe on any host: uid 0 always fails, root or not.
  it "serializes a useradd command failure as [name, rc, failed, msg, changed, exception]" do
    result = PluginSpecHelper.run("user", {
      "name" => "krikri-kop-uidfail", "uid" => "0",
    })

    result["failed"].as_bool.must_equal(true)
    result["name"].as_s.must_equal("krikri-kop-uidfail")
    result["rc"].as_i?.wont_be_nil
    result.as_h.keys.must_equal(["name", "rc", "failed", "msg", "changed", "exception"])
    `getent passwd krikri-kop-uidfail`.strip.must_be_empty
  end
end

describe "group plugin result key order" do
  it "serializes a check-mode create of a missing group as just [changed]" do
    result = PluginSpecHelper.run("group", {
      "name" => "krikri-kop-nogroup", "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed"])
  end

  it "serializes a check-mode modify of an existing group as the full exists-after shape" do
    result = PluginSpecHelper.run("group", {
      "name" => "root", "gid" => "999999", "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["name", "state", "changed", "system", "gid"])
  end

  it "serializes an absent no-op as [name, state, changed]" do
    result = PluginSpecHelper.run("group", {
      "name" => "krikri-kop-nogroup", "state" => "absent",
    })

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["name", "state", "changed"])
  end

  it "serializes a check-mode removal of an existing group as just [changed]" do
    result = PluginSpecHelper.run("group", {
      "name" => "root", "state" => "absent", "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed"])
  end

  # Ansible's group command failures are fail_json(name=group.name, msg=err)
  # - the name kwarg LEADS, before failed/msg (round 992000's group_fail:
  # [name, failed, msg, changed, exception]). Safe on any host: gid_max
  # below gid_min makes groupadd refuse without creating anything, root
  # or not.
  it "serializes a groupadd command failure as [name, failed, msg, changed, exception]" do
    result = PluginSpecHelper.run("group", {
      "name" => "krikri-kop-gidfail", "gid_max" => "86",
    })

    result["failed"].as_bool.must_equal(true)
    result["name"].as_s.must_equal("krikri-kop-gidfail")
    result.as_h.keys.must_equal(["name", "failed", "msg", "changed", "exception"])
  end
end
