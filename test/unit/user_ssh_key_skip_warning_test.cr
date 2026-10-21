require "../minitest_helper"

# Regression spec for issue #197 (abaez.sudo): ansible-core's user.py
# ssh_key_gen WARNS and skips generation when the key file already exists
# and force is not set - private file checked before the public one -
# while krikri's no-op branch used to return silently. Exercised through
# the real plugin binary against a temp directory with an ABSOLUTE
# ssh_key_file (relative paths resolve against the account's real home,
# which would mutate a developer's own ~/.ssh); no account is created,
# modified, or removed here.
private TEST_USER = ENV["USER"]?.try(&.empty?) == false ? ENV["USER"] : `id -un`.strip

describe "user plugin generate_ssh_key existing-key warnings" do
  it "warns with the private path and stays ok when the private file exists" do
    dir = PluginSpecHelper.tmp_path("user-ssh-key-warn-priv")
    FileUtils.mkdir_p(dir)
    key_path = File.join(dir, "id_ed25519")
    File.write(key_path, "not a real key")

    result = PluginSpecHelper.run("user", {
      "name"             => TEST_USER,
      "generate_ssh_key" => "true",
      "ssh_key_type"     => "ed25519",
      "ssh_key_file"     => key_path,
    })

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    warnings = result["warnings"].as_a
    warnings.size.must_equal(1)
    warnings[0].as_s.must_equal(
      "Found existing ssh key private file \"#{key_path}\", no force, so skipping ssh-keygen generation")
    result["ssh_key_file"]?.must_be_nil
    result["ssh_public_key"]?.must_be_nil
    result["ssh_fingerprint"]?.must_be_nil
  end

  it "warns with the public path when only the public file exists" do
    dir = PluginSpecHelper.tmp_path("user-ssh-key-warn-pub")
    FileUtils.mkdir_p(dir)
    key_path = File.join(dir, "id_ed25519")
    File.write(key_path + ".pub", "ssh-ed25519 AAAA krikri-spec")

    result = PluginSpecHelper.run("user", {
      "name"             => TEST_USER,
      "generate_ssh_key" => "true",
      "ssh_key_type"     => "ed25519",
      "ssh_key_file"     => key_path,
    })

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    warnings = result["warnings"].as_a
    warnings.size.must_equal(1)
    warnings[0].as_s.must_equal(
      "Found existing ssh key public file \"#{key_path}.pub\", no force, so skipping ssh-keygen generation")
  end

  it "carries no warning when no key file exists (check-mode would-generate)" do
    dir = PluginSpecHelper.tmp_path("user-ssh-key-warn-absent")
    FileUtils.mkdir_p(dir)
    key_path = File.join(dir, "id_ed25519")

    result = PluginSpecHelper.run("user", {
      "name"                => TEST_USER,
      "generate_ssh_key"    => "true",
      "ssh_key_type"        => "ed25519",
      "ssh_key_file"        => key_path,
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["warnings"]?.must_be_nil
  end
end
