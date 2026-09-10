require "file_utils"
require "../spec_helper"

# Regression spec for round 84001 (abaez.user): the user plugin never read
# generate_ssh_key: (or any of its ssh_key_* friends) at all, so a
# `generate_ssh_key: yes` task never generated a keypair and always
# reported ok where real Ansible generates via ssh-keygen and reports
# changed. These specs exercise the real plugin binary against a temp
# directory via an ABSOLUTE ssh_key_file (relative paths resolve against
# the account's real home, which would mutate a developer's own ~/.ssh) -
# no account is created, modified, or removed here.
private TEST_USER = ENV["USER"]?.try(&.empty?) == false ? ENV["USER"] : `id -un`.strip

describe "user plugin generate_ssh_key" do
  it "generates the keypair for a missing key and reports changed" do
    dir = File.tempname("krikri-ssh-key")
    Dir.mkdir_p(dir)
    key_path = File.join(dir, "id_ed25519")

    begin
      result = PluginSpecHelper.run("user", {
        "name"             => TEST_USER,
        "generate_ssh_key" => "true",
        "ssh_key_type"     => "ed25519",
        "ssh_key_file"     => key_path,
        "ssh_key_comment"  => "krikri-spec",
      })

      result["changed"].as_bool.should be_true
      result["failed"]?.try(&.as_bool).should be_falsey
      result["ssh_key_file"].as_s.should eq(key_path)
      result["ssh_public_key"].as_s.should contain("ssh-ed25519")
      result["ssh_public_key"].as_s.should contain("krikri-spec")
      result["ssh_fingerprint"].as_s.should contain("SHA256:")
      File.exists?(key_path).should be_true
      File.exists?(key_path + ".pub").should be_true
      File.read(key_path).should contain("PRIVATE KEY")
    ensure
      FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
    end
  end

  it "reports ok on rerun without regenerating (idempotent, key preserved)" do
    dir = File.tempname("krikri-ssh-key")
    Dir.mkdir_p(dir)
    key_path = File.join(dir, "id_ed25519")

    begin
      PluginSpecHelper.run("user", {
        "name"             => TEST_USER,
        "generate_ssh_key" => "true",
        "ssh_key_type"     => "ed25519",
        "ssh_key_file"     => key_path,
      })

      # Sanity: the first run really did create the key.
      File.exists?(key_path).should be_true
      before = File.read(key_path)

      result = PluginSpecHelper.run("user", {
        "name"             => TEST_USER,
        "generate_ssh_key" => "true",
        "ssh_key_type"     => "ed25519",
        "ssh_key_file"     => key_path,
      })

      result["changed"].as_bool.should be_false
      File.read(key_path).should eq(before)
    ensure
      FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
    end
  end

  it "would generate in check mode without creating anything" do
    dir = File.tempname("krikri-ssh-key")
    Dir.mkdir_p(dir)
    key_path = File.join(dir, "id_ed25519")

    begin
      result = PluginSpecHelper.run("user", {
        "name"             => TEST_USER,
        "generate_ssh_key" => "true",
        "ssh_key_file"     => key_path,
        "check_mode"       => "true",
      })

      result["changed"].as_bool.should be_true
      result["msg"].as_s.should contain("check mode")
      File.exists?(key_path).should be_false
    ensure
      FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
    end
  end
end
