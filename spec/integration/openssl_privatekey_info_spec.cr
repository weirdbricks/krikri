require "../spec_helper"
require "file_utils"

# community.crypto.openssl_privatekey_info - read-only private key
# facts. Result shape matched against the real module (community.crypto
# 3.1.1): can_load_key/can_parse_key always present, key_is_consistent
# nil unless checked, PEM public key, all-algorithm fingerprints of the
# DER SubjectPublicKeyInfo, type + public_data per key type.
private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "openssl_privatekey_info")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

describe "openssl_privatekey_info plugin" do
  it "reports can_load_key/can_parse_key, the PEM public key, fingerprints and RSA facts" do
    path = File.join(TMP_DIR, "rsa.key")
    `openssl genrsa -out #{path} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_privatekey_info", {"path" => path})

    result["failed"].as_bool.should be_false
    result["can_load_key"].as_bool.should be_true
    result["can_parse_key"].as_bool.should be_true
    # key_is_consistent stays nil unless check_consistency: true - the
    # real module leaves it None there too.
    result["key_is_consistent"].as_s?.should be_nil
    result["type"].as_s.should eq("RSA")
    result["public_key"].as_s.should contain("-----BEGIN PUBLIC KEY-----")
    public_data = result["public_data"].as_h
    public_data["size"].as_i.should eq(2048)
    public_data["exponent"].as_i.should eq(65537)
    # The modulus is wider than Int64 - emitted as its exact decimal
    # string (309 digits for a 1024-bit... 2048-bit key) rather than
    # truncated through a float.
    modulus = public_data["modulus"].as_s
    modulus.size.should eq(617)
    fingerprints = result["public_key_fingerprints"].as_h
    fingerprints["sha256"].as_s.should match(/^(..:){31}..$/)
    fingerprints["md5"].as_s.should match(/^(..:){15}..$/)
  end

  it "reports ECC facts: curve, exponent_size, decimal x/y coordinates" do
    path = File.join(TMP_DIR, "ec.key")
    `openssl ecparam -genkey -name prime256v1 -out #{path} 2>/dev/null`

    result = PluginSpecHelper.run("openssl_privatekey_info", {"path" => path})

    result["type"].as_s.should eq("ECC")
    public_data = result["public_data"].as_h
    public_data["curve"].as_s.should eq("prime256v1")
    public_data["exponent_size"].as_i.should eq(256)
    # Both coordinates are 77-78 digit decimals for a 256-bit curve.
    public_data["x"].as_s.size.should be >= 70
    public_data["x"].as_s.size.should be <= 80
    public_data["y"].as_s.size.should be >= 70
    public_data["y"].as_s.size.should be <= 80
  end

  it "fails with can_parse_key false for an unparseable key" do
    path = File.join(TMP_DIR, "garbage.key")
    File.write(path, "this is not a key")

    result = PluginSpecHelper.run("openssl_privatekey_info", {"path" => path})

    result["failed"].as_bool.should be_true
    result["can_load_key"].as_bool.should be_true
    result["can_parse_key"].as_bool.should be_false
  end

  it "fails for a missing file with can_load_key false" do
    result = PluginSpecHelper.run("openssl_privatekey_info",
      {"path" => File.join(TMP_DIR, "nope.key")})

    result["failed"].as_bool.should be_true
    result["can_load_key"].as_bool.should be_false
    result["can_parse_key"].as_bool.should be_false
  end

  it "decrypts a passphrase-protected key" do
    path = File.join(TMP_DIR, "enc.key")
    `openssl genrsa -aes256 -passout pass:s3cret -out #{path} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_privatekey_info",
      {"path" => path, "passphrase" => "s3cret"})

    result["failed"].as_bool.should be_false
    result["type"].as_s.should eq("RSA")

    wrong = PluginSpecHelper.run("openssl_privatekey_info",
      {"path" => path, "passphrase" => "wrong"})
    wrong["failed"].as_bool.should be_true
    wrong["can_parse_key"].as_bool.should be_false
  end
end
