require "../minitest_helper"
require "file_utils"

# community.crypto.openssl_privatekey_info - read-only private key
# facts. Result shape matched against the Ansible module (community.crypto
# 3.1.1): can_load_key/can_parse_key always present, key_is_consistent
# nil unless checked, PEM public key, all-algorithm fingerprints of the
# DER SubjectPublicKeyInfo, type + public_data per key type.
# The classic suite pre-created a shared spec/tmp root in before_suite;
# every test now gets its own tmp_path subtree.
describe "openssl_privatekey_info plugin" do
  it "reports can_load_key/can_parse_key, the PEM public key, fingerprints and RSA facts" do
    path = PluginSpecHelper.tmp_path("rsa.key")
    `openssl genrsa -out #{path} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_privatekey_info", {"path" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["can_load_key"].as_bool.must_equal(true)
    result["can_parse_key"].as_bool.must_equal(true)
    # key_is_consistent stays nil unless check_consistency: true - the
    # real module leaves it None there too.
    result["key_is_consistent"].as_s?.must_be_nil
    result["type"].as_s.must_equal("RSA")
    result["public_key"].as_s.must_include("-----BEGIN PUBLIC KEY-----")
    public_data = result["public_data"].as_h
    public_data["size"].as_i.must_equal(2048)
    public_data["exponent"].as_i.must_equal(65537)
    # The modulus is wider than Int64 - emitted as its exact decimal
    # string (309 digits for a 1024-bit... 2048-bit key) rather than
    # truncated through a float.
    modulus = public_data["modulus"].as_s
    modulus.size.must_equal(617)
    fingerprints = result["public_key_fingerprints"].as_h
    fingerprints["sha256"].as_s.must_match(/^(..:){31}..$/)
    fingerprints["md5"].as_s.must_match(/^(..:){15}..$/)
  end

  it "reports ECC facts: curve, exponent_size, decimal x/y coordinates" do
    path = PluginSpecHelper.tmp_path("ec.key")
    `openssl ecparam -genkey -name prime256v1 -out #{path} 2>/dev/null`

    result = PluginSpecHelper.run("openssl_privatekey_info", {"path" => path})

    result["type"].as_s.must_equal("ECC")
    public_data = result["public_data"].as_h
    public_data["curve"].as_s.must_equal("prime256v1")
    public_data["exponent_size"].as_i.must_equal(256)
    # Both coordinates are 77-78 digit decimals for a 256-bit curve.
    (public_data["x"].as_s.size >= 70).must_equal(true)
    (public_data["x"].as_s.size <= 80).must_equal(true)
    (public_data["y"].as_s.size >= 70).must_equal(true)
    (public_data["y"].as_s.size <= 80).must_equal(true)
  end

  it "fails with can_parse_key false for an unparseable key" do
    path = PluginSpecHelper.tmp_path("garbage.key")
    File.write(path, "this is not a key")

    result = PluginSpecHelper.run("openssl_privatekey_info", {"path" => path})

    result["failed"].as_bool.must_equal(true)
    result["can_load_key"].as_bool.must_equal(true)
    result["can_parse_key"].as_bool.must_equal(false)
  end

  it "fails for a missing file with can_load_key false" do
    result = PluginSpecHelper.run("openssl_privatekey_info",
      {"path" => PluginSpecHelper.tmp_path("nope.key")})

    result["failed"].as_bool.must_equal(true)
    result["can_load_key"].as_bool.must_equal(false)
    result["can_parse_key"].as_bool.must_equal(false)
  end

  it "decrypts a passphrase-protected key" do
    path = PluginSpecHelper.tmp_path("enc.key")
    `openssl genrsa -aes256 -passout pass:s3cret -out #{path} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_privatekey_info",
      {"path" => path, "passphrase" => "s3cret"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["type"].as_s.must_equal("RSA")

    wrong = PluginSpecHelper.run("openssl_privatekey_info",
      {"path" => path, "passphrase" => "wrong"})
    wrong["failed"].as_bool.must_equal(true)
    wrong["can_parse_key"].as_bool.must_equal(false)
  end
end
