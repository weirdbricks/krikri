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
    # Ansible module leaves it None there too.
    result["key_is_consistent"].as_s?.must_be_nil
    result["type"].as_s.must_equal("RSA")
    result["public_key"].as_s.must_include("-----BEGIN PUBLIC KEY-----")
    public_data = result["public_data"].as_h
    public_data["size"].as_i.must_equal(2048)
    public_data["exponent"].as_i.must_equal(65537)
    # The modulus is wider than Int64 - a real wide integer, carried as
    # the BIGINT_SENTINEL_PREFIX-marked decimal string (its exact digits,
    # 617 for a 2048-bit key, unquoted by every renderer) rather than
    # truncated through a float.
    modulus = Krikri.bigint_digits(public_data["modulus"]).not_nil!
    modulus.size.must_equal(617)
    fingerprints = result["public_key_fingerprints"].as_h
    fingerprints["sha256"].as_s.must_match(/^(..:){31}..$/)
    fingerprints["md5"].as_s.must_match(/^(..:){15}..$/)
  end

  it "warns 'Cannot determine consistency' with key_is_consistent nil for check_consistency on an RSA key" do
    path = PluginSpecHelper.tmp_path("rsa-consistency.key")
    `openssl genrsa -out #{path} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_privatekey_info",
      {"path" => path, "check_consistency" => "true"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    # cryptography >= 42 dropped key._backend, so community.crypto cannot
    # run its RSA_check_key consistency check for RSA and warns instead
    # of returning a verdict (DSA/ECC/Ed25519/Ed448 sign-verify silently).
    result["key_is_consistent"].as_s?.must_be_nil
    warnings = result["warnings"]?.try(&.as_a?) || [] of JSON::Any
    warnings.size.must_equal(1)
    warnings[0].as_s.must_equal(
      "Cannot determine consistency for key of type " \
      "<class 'cryptography.hazmat.bindings._rust.openssl.rsa.RSAPrivateKey'>")
  end

  it "reports ECC facts: curve, exponent_size, decimal x/y coordinates" do
    path = PluginSpecHelper.tmp_path("ec.key")
    `openssl ecparam -genkey -name prime256v1 -out #{path} 2>/dev/null`

    result = PluginSpecHelper.run("openssl_privatekey_info", {"path" => path})

    result["type"].as_s.must_equal("ECC")
    public_data = result["public_data"].as_h
    # cryptography's curve.name, as the module reports it (live: secp256r1, not openssl's prime256v1)
    public_data["curve"].as_s.must_equal("secp256r1")
    public_data["exponent_size"].as_i.must_equal(256)
    # Both coordinates are 77-78 digit decimals for a 256-bit curve,
    # carried as marked wide integers (see the modulus note above).
    x = Krikri.bigint_digits(public_data["x"]).not_nil!
    y = Krikri.bigint_digits(public_data["y"]).not_nil!
    (x.size >= 70).must_equal(true)
    (x.size <= 80).must_equal(true)
    (y.size >= 70).must_equal(true)
    (y.size <= 80).must_equal(true)
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
