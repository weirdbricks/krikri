require "../minitest_helper"

# Pins plugins/openssh_keypair.cr's backend-selection and validation
# order against real community.crypto.openssh_keypair (live-diffed vs
# ansible-playbook 2.19.11): the size validation runs for EVERY
# state (before the absent branch), and the opensshbin backend rejects
# any private_key_format other than auto.
describe "openssh_keypair backend selection" do
  it "validates the size even for state=absent" do
    work = PluginSpecHelper.tmp_path("keypair-absent-size")
    Dir.mkdir_p(work)

    result = PluginSpecHelper.run("openssh_keypair", {
      "state" => "absent",
      "path"  => File.join(work, "id_test"),
      "type"  => "rsa",
      "size"  => "100",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "For RSA keys, the minimum size is 1024 bits and the default is 4096 bits. " \
      "Attempting to use bit lengths under 1024 will cause the module to fail.")
  end

  it "rejects a non-auto private_key_format on the opensshbin backend" do
    work = PluginSpecHelper.tmp_path("keypair-format")
    Dir.mkdir_p(work)

    result = PluginSpecHelper.run("openssh_keypair", {
      "path"               => File.join(work, "id_test"),
      "backend"            => "opensshbin",
      "private_key_format" => "pkcs8",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "'auto' is the only valid option for 'private_key_format' when 'backend' is not 'cryptography'")
  end

  it "fails an out-of-range ECDSA size with the updated wording" do
    work = PluginSpecHelper.tmp_path("keypair-ecdsa-size")
    Dir.mkdir_p(work)

    result = PluginSpecHelper.run("openssh_keypair", {
      "path" => File.join(work, "id_test"),
      "type" => "ecdsa",
      "size" => "512",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "For ECDSA keys, size determines the key length by selecting from one of three elliptic curve sizes: " \
      "256, 384 or 521 bits. Attempting to use bit lengths other than these three values for ECDSA keys " \
      "will cause this module to fail.")
  end

  it "keeps community.crypto's own 'this module' wording for a tiny ECDSA size" do
    work = PluginSpecHelper.tmp_path("keypair-ecdsa-size-tiny")
    Dir.mkdir_p(work)

    result = PluginSpecHelper.run("openssh_keypair", {
      "path" => File.join(work, "id_test"),
      "type" => "ecdsa",
      "size" => "2",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "For ECDSA keys, size determines the key length by selecting from one of three elliptic curve sizes: " \
      "256, 384 or 521 bits. Attempting to use bit lengths other than these three values for ECDSA keys " \
      "will cause this module to fail.")
  end

  it "reports public_key without the comment" do
    work = PluginSpecHelper.tmp_path("keypair-pubkey-comment")
    Dir.mkdir_p(work)

    result = PluginSpecHelper.run("openssh_keypair", {
      "path"    => File.join(work, "id_test"),
      "type"    => "ed25519",
      "comment" => "Created by ansible",
    })
    result["comment"].as_s.must_equal("Created by ansible")
    result["public_key"].as_s.split(' ').size.must_equal(2)
  end

  it "fails an existing file that is not a private key for the default regenerate mode" do
    work = PluginSpecHelper.tmp_path("keypair-unreadable-file")
    Dir.mkdir_p(work)
    # The kpg corpus seeds /tmp/kpg-work/dest-0400.txt with plain text, and
    # community.crypto's KeypairBackend._validate_key_load aborts (rather
    # than regenerating) for every regenerate mode but the two that allow
    # replacing a broken key.
    path = File.join(work, "id_test")
    File.write(path, "kpg locked dest\nsecond line\n")
    File.chmod(path, 0o400)

    result = PluginSpecHelper.run("openssh_keypair", {
      "path"                => path,
      "_ansible_check_mode" => "true",
    })
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(
      "Unable to read the key. The key is protected with a passphrase or broken. " \
      "Will not proceed. To force regeneration, call the module with `generate` set to " \
      "`full_idempotence` or `always`, or with `force=true`.")
  end

  it "regenerates an unreadable existing key when regenerate allows it" do
    work = PluginSpecHelper.tmp_path("keypair-regenerate-broken")
    Dir.mkdir_p(work)
    path = File.join(work, "id_test")
    File.write(path, "not a key\n")

    result = PluginSpecHelper.run("openssh_keypair", {
      "path"                => path,
      "regenerate"          => "full_idempotence",
      "_ansible_check_mode" => "true",
    })
    (result["failed"]?.try(&.as_bool) || false).must_equal(false)
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Would generate SSH keypair at #{path} (check mode)")
  end
end
