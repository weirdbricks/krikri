require "file_utils"
require "../minitest_helper"

# Regression spec for round 84001 (abaez.user): the user plugin never read
# generate_ssh_key: (or any of its ssh_key_* friends) at all, so a
# `generate_ssh_key: yes` task never generated a keypair and always
# reported ok where Ansible generates via ssh-keygen and reports
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

      result["changed"].as_bool.must_equal(true)
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["ssh_key_file"].as_s.must_equal(key_path)
      result["ssh_public_key"].as_s.must_include("ssh-ed25519")
      result["ssh_public_key"].as_s.must_include("krikri-spec")
      result["ssh_fingerprint"].as_s.must_include("SHA256:")
      File.exists?(key_path).must_equal(true)
      File.exists?(key_path + ".pub").must_equal(true)
      File.read(key_path).must_include("PRIVATE KEY")
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
      File.exists?(key_path).must_equal(true)
      before = File.read(key_path)

      result = PluginSpecHelper.run("user", {
        "name"             => TEST_USER,
        "generate_ssh_key" => "true",
        "ssh_key_type"     => "ed25519",
        "ssh_key_file"     => key_path,
      })

      result["changed"].as_bool.must_equal(false)
      File.read(key_path).must_equal(before)
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
        "name"                => TEST_USER,
        "generate_ssh_key"    => "true",
        "ssh_key_file"        => key_path,
        "_ansible_check_mode" => "true",
      })

      result["changed"].as_bool.must_equal(true)
      File.exists?(key_path).must_equal(false)
    ensure
      FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
    end
  end

  # A missing home directory is real user.py's ssh_key_gen failure, and
  # main() reports it the way it reports every other command failure:
  # fail_json(name=..., msg=..., rc=1). The account name and rc were
  # missing from this engine's result, so a `register:`d failure carried
  # a bare msg (found by the kpg30 sweep on `user: {name: ...,
  # create_home: false, generate_ssh_key: true}`, live-verified against
  # 2.19.11). Exercised through an account whose passwd home simply
  # does not exist (nobody, on Debian/Ubuntu), so no account is created,
  # modified or removed here.
  it "fails with the account name and rc when the account's home directory does not exist" do
    line = `getent passwd`.split("\n").find do |entry|
      home = entry.split(":")[5]?
      home && !home.empty? && !File.directory?(home)
    end
    skip "no account with a missing home directory on this host" unless line
    account_name = line.not_nil!.split(":")[0]

    result = PluginSpecHelper.run("user", {
      "name"             => account_name,
      "generate_ssh_key" => "true",
      "ssh_key_type"     => "ed25519",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("User #{account_name} home directory does not exist")
    result["name"].as_s.must_equal(account_name)
    result["rc"].as_i.must_equal(1)
  end
end
