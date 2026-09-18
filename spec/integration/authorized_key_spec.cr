require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

private RSA_KEY = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC test@example.com"

describe "authorized_key plugin" do
  it "creates the file (and the .ssh dir itself, real Ansible's single os.mkdir) and adds the key" do
    # Real Ansible's keyfile() does os.mkdir on the .ssh dir only - a
    # missing grandparent is a real "Failed to create directory" OSError
    # (verified live), so the spec's base dir must exist up front.
    base = tmp_path("authorized-key-create")
    `rm -rf #{base} && mkdir -p #{base}`
    path = File.join(base, ".ssh", "authorized_keys")

    result = PluginSpecHelper.run("authorized_key", {"path" => path, "key" => RSA_KEY})

    result["changed"].as_bool.should be_true
    File.read(path).should contain(RSA_KEY)
    File.info(File.join(base, ".ssh")).permissions.should eq(File::Permissions.new(0o700))
  end

  it "no-ops on an empty key, without even creating the file (matches real Ansible)" do
    # Real bug found benchmarking weareinteractive.users' own `key: "{{
    # user.authorized_keys | default([]) | join('\n') }}"` (empty
    # whenever a user has no authorized_keys set) - previously always
    # added a blank line and could never recognize it as already-present
    # on rerun (a blank line's key signature is nil, and blank lines are
    # filtered out of the comparison list before the signature check
    # runs), so it reported changed: true on every single run forever.
    # Real Ansible's own module doesn't even create the file for an
    # empty key - verified live against real ansible-playbook.
    path = File.join(tmp_path("authorized-key-empty"), ".ssh", "authorized_keys")
    `rm -rf #{tmp_path("authorized-key-empty")}`

    result = PluginSpecHelper.run("authorized_key", {"path" => path, "key" => ""})
    result["changed"].as_bool.should be_false
    File.exists?(path).should be_false

    result2 = PluginSpecHelper.run("authorized_key", {"path" => path, "key" => ""})
    result2["changed"].as_bool.should be_false
  end

  it "is idempotent when the key is already present" do
    path = tmp_path("authorized-key-idempotent")
    File.write(path, "#{RSA_KEY}\n")

    result = PluginSpecHelper.run("authorized_key", {"path" => path, "key" => RSA_KEY})

    result["changed"].as_bool.should be_false
  end

  it "treats a key with a different trailing comment as the same key" do
    path = tmp_path("authorized-key-comment")
    File.write(path, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC different-comment\n")

    result = PluginSpecHelper.run("authorized_key", {"path" => path, "key" => RSA_KEY})

    result["changed"].as_bool.should be_false
  end

  it "removes the key when state=absent" do
    path = tmp_path("authorized-key-remove")
    File.write(path, "#{RSA_KEY}\nssh-ed25519 AAAAC3 other@host\n")

    result = PluginSpecHelper.run("authorized_key", {"path" => path, "key" => RSA_KEY, "state" => "absent"})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should_not contain("ssh-rsa")
    content.should contain("ssh-ed25519")
  end

  it "does not write to disk in check mode" do
    path = tmp_path("authorized-key-check-mode")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("authorized_key", {"path" => path, "key" => RSA_KEY, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.should be_true
    File.exists?(path).should be_false
  end

  it "resolves the keyfile path from a user's home directory (NSS) when no path override is given" do
    result = PluginSpecHelper.run("authorized_key", {"user" => "root", "key" => RSA_KEY, "_ansible_check_mode" => "true"})

    result["failed"]?.try(&.as_bool).should be_falsey
    # Real Ansible echoes the resolved path back as `keyfile` (its own
    # params["keyfile"] set by enforce_state); the `path` echo is the
    # raw `path:` param, i.e. JSON null when not given.
    result["keyfile"].as_s.should eq("/root/.ssh/authorized_keys")
    result["path"].raw.should be_nil
  end

  it "fails with a clear message when neither user nor path is given" do
    result = PluginSpecHelper.run("authorized_key", {"key" => RSA_KEY})

    result["failed"].as_bool.should be_true
  end

  # Round 811277 (jtprogru.profile): a role default left a username that
  # doesn't exist on the host, and krikri silently "succeeded" by
  # inventing /home/<user>/.ssh/authorized_keys for it. Real Ansible's
  # keyfile() does a real pwd.getpwnam(user) and hard-fails instead.
  # All messages below verified live against real ansible-playbook
  # (ansible.posix 2.1.0).
  it "fails like real Ansible when the user doesn't exist and no path is given" do
    result = PluginSpecHelper.run("authorized_key", {
      "user" => "definitely-not-a-user-xyz", "key" => RSA_KEY,
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Failed to lookup user definitely-not-a-user-xyz: \"getpwnam(): name not found: 'definitely-not-a-user-xyz'\""
    )
  end

  it "fails in check mode with real Ansible's own check-mode message for a nonexistent user" do
    result = PluginSpecHelper.run("authorized_key", {
      "user" => "definitely-not-a-user-xyz", "key" => RSA_KEY, "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Either user must exist or you must provide full path to key file in check mode")
  end

  it "fails in normal mode even with an explicit path when the user doesn't exist (real Ansible still does the lookup for ownership)" do
    path = File.join(tmp_path("authorized-key-explicit-no-user"), ".ssh", "authorized_keys")
    `rm -rf #{tmp_path("authorized-key-explicit-no-user")}`

    result = PluginSpecHelper.run("authorized_key", {
      "user" => "definitely-not-a-user-xyz", "path" => path, "key" => RSA_KEY,
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Failed to lookup user definitely-not-a-user-xyz: \"getpwnam(): name not found: 'definitely-not-a-user-xyz'\""
    )
  end

  it "skips the user lookup entirely in check mode with an explicit path (real Ansible's early return)" do
    path = File.join(tmp_path("authorized-key-explicit-cm"), ".ssh", "authorized_keys")
    `rm -rf #{tmp_path("authorized-key-explicit-cm")}`

    result = PluginSpecHelper.run("authorized_key", {
      "user" => "definitely-not-a-user-xyz", "path" => path, "key" => RSA_KEY, "_ansible_check_mode" => "true",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
  end

  it "still succeeds for a user that genuinely exists, resolving the real NSS home" do
    result = PluginSpecHelper.run("authorized_key", {"user" => "root", "key" => RSA_KEY, "_ansible_check_mode" => "true"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["keyfile"].as_s.should eq("/root/.ssh/authorized_keys")
  end

  # Ad-hoc CLI comparison sweep vs real ansible (2026-09-13): real
  # ansible.posix.authorized_key returns its ENTIRE module.params dict
  # (with keyfile/changed merged in), so every effective parameter -
  # including defaulted (manage_dir/exclusive/validate_certs/follow) and
  # absent (comment/key_options/user -> JSON null) ones - is echoed back,
  # plus AnsibleModule.add_path_info's stat fields whenever the echoed
  # `path` param points at an existing file. Previously only
  # changed/msg/path/state came back.
  it "echoes the full effective parameter set plus file stat fields (real module's exit_json(**params) shape)" do
    path = tmp_path("authorized-key-fields")
    File.write(path, "#{RSA_KEY}\n")

    result = PluginSpecHelper.run("authorized_key", {
      "path" => path, "key" => RSA_KEY,
      "key_options" => "no-port-forwarding", "comment" => "krikri test",
    })

    result["changed"].as_bool.should be_false
    result["user"].raw.should be_nil
    result["key"].as_s.should eq(RSA_KEY)
    result["path"].as_s.should eq(path)
    result["keyfile"].as_s.should eq(path)
    result["manage_dir"].as_bool.should be_true
    result["key_options"].as_s.should eq("no-port-forwarding")
    result["exclusive"].as_bool.should be_false
    result["comment"].as_s.should eq("krikri test")
    result["validate_certs"].as_bool.should be_true
    result["follow"].as_bool.should be_false
    result["msg"]?.should be_nil
    result["uid"].as_i64.should eq(File.info(path, follow_symlinks: false).owner_id.to_i64)
    result["gid"].as_i64.should eq(File.info(path, follow_symlinks: false).group_id.to_i64)
    result["owner"].as_s.should_not be_empty
    result["group"].as_s.should_not be_empty
    result["mode"].as_s.should match(/\A0[0-7]{3,4}\z/)
    result["state"].as_s.should eq("file")
    result["size"].as_i64.should eq(RSA_KEY.bytesize + 1)
  end

  # podman-diff authorized_key_edge_cases (2026-09-15): real
  # ansible.posix.authorized_key splits the key into lines, drops blank
  # and '#'-prefixed ones, and hard-fails on the FIRST line without a
  # known SSH2 key-type token ("invalid key specified:") - garbage is
  # never silently appended.
  it "fails with real Ansible's invalid-key message on garbage key material" do
    path = tmp_path("authorized-key-invalid")
    `rm -rf #{tmp_path("authorized-key-invalid")}`

    result = PluginSpecHelper.run("authorized_key", {
      "path" => path, "key" => "krikri-not-a-key at all",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("invalid key specified: krikri-not-a-key at all")
    File.exists?(path).should be_false
  end

  # round 825388 batch (lucasmaurice.users, jtprogru.hosts): real
  # ansible.posix.authorized_key fetches a key that looks like a URL
  # (http/https/ftp/file) before line-splitting - "invalid key
  # specified: https://github.com/bob.keys" never happens on real
  # Ansible. file:// is spec'd here (network-independent); the http(s)
  # path shares the same dispatch.
  it "fetches a file:// URL key instead of failing with invalid-key" do
    key_file = tmp_path("authorized-key-url-src")
    `rm -rf #{key_file}`
    File.write(key_file, RSA_KEY)
    path = tmp_path("authorized-key-url")
    `rm -rf #{tmp_path("authorized-key-url")}`

    result = PluginSpecHelper.run("authorized_key", {
      "path" => path, "key" => "file://#{key_file}",
    })

    File.read(path).should contain(RSA_KEY)
  end

  it "fails with a fetch error message when a file:// URL key is missing" do
    path = tmp_path("authorized-key-url-missing")
    `rm -rf #{tmp_path("authorized-key-url-missing")}`

    result = PluginSpecHelper.run("authorized_key", {
      "path" => path, "key" => "file://#{tmp_path("does-not-exist.keys")}",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Failed to fetch")
    File.exists?(path).should be_false
  end

  it "accepts a multi-line key param, landing every key" do
    path = tmp_path("authorized-key-multi")
    `rm -rf #{tmp_path("authorized-key-multi")}`
    k1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOkrim1 m1@example"
    k2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOkrim2 m2@example"

    result = PluginSpecHelper.run("authorized_key", {
      "path" => path, "key" => "#{k1}\n#{k2}",
    })

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should contain(k1)
    content.should contain(k2)
  end

  it "honors exclusive=true by removing keys not in the new key set" do
    path = tmp_path("authorized-key-exclusive")
    `rm -rf #{tmp_path("authorized-key-exclusive")}`
    keep = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOkriex exclusive@example"

    PluginSpecHelper.run("authorized_key", {"path" => path, "key" => RSA_KEY})
    result = PluginSpecHelper.run("authorized_key", {
      "path" => path, "key" => keep, "exclusive" => "true",
    })

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should eq("#{keep}\n")
  end

  it "rewrites the line as '<key_options> <type> <blob> <comment>' when key_options is given" do
    path = tmp_path("authorized-key-options")
    `rm -rf #{tmp_path("authorized-key-options")}`

    result = PluginSpecHelper.run("authorized_key", {
      "path" => path, "key" => RSA_KEY,
      "key_options" => "command=\"echo hi\",no-pty",
    })

    result["changed"].as_bool.should be_true
    File.read(path).should contain("command=\"echo hi\",no-pty ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC test@example.com")
  end
end
