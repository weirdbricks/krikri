require "../minitest_helper"

# Pins plugins/openssh_keypair.cr's backend-selection and validation
# order against real community.crypto.openssh_keypair (live-diffed vs
# real ansible-playbook 2.19.11): the size validation runs for EVERY
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
      "will cause the module to fail.")
  end
end
