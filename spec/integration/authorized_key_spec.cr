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
  it "creates the file (and .ssh-style parent dir) and adds the key" do
    path = File.join(tmp_path("authorized-key-create"), ".ssh", "authorized_keys")
    `rm -rf #{tmp_path("authorized-key-create")}`

    result = PluginSpecHelper.run("authorized_key", {"path" => path, "key" => RSA_KEY})

    result["changed"].as_bool.should be_true
    File.read(path).should contain(RSA_KEY)
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

    result = PluginSpecHelper.run("authorized_key", {"path" => path, "key" => RSA_KEY, "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    File.exists?(path).should be_false
  end

  it "resolves the path from a user's home directory (NSS) when no path override is given" do
    result = PluginSpecHelper.run("authorized_key", {"user" => "root", "key" => RSA_KEY, "check_mode" => "true"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["path"].as_s.should eq("/root/.ssh/authorized_keys")
  end

  it "fails with a clear message when neither user nor path is given" do
    result = PluginSpecHelper.run("authorized_key", {"key" => RSA_KEY})

    result["failed"].as_bool.should be_true
  end
end
