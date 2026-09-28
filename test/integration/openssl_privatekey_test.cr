require "../minitest_helper"
require "file_utils"

# community.crypto.openssl_privatekey. Every expectation here was
# differentialed against the real module (community.crypto 3.1.1 on
# ansible-core 2.19.4) rather than taken from its documentation - the
# idempotency matrix in particular, which is what roles like
# robertdebock.openssl, buluma.ca and mrlesmithjr.haproxy depend on
# across reruns.

# The classic suite pre-created a shared spec/tmp root in before_suite;
# every test now gets its own tmp_path subtree.
private def key_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

# Under minitest the tests are shuffled and run concurrently, so any
# test that reads an existing key seeds it into its own tmp_path subtree
# first (the classic suite inherited rsa.key/pw.key/ec.key state from
# the linear test order).
private def seed_key(path : String, params : Hash(String, String)) : Nil
  return if File.exists?(path)
  PluginSpecHelper.run("openssl_privatekey", params.merge({"path" => path}))
end

private def key_text(path : String, passphrase : String? = nil) : String
  args = ["pkey", "-in", path, "-noout", "-text"]
  args.concat(["-passin", "pass:#{passphrase}"]) if passphrase
  `openssl #{args.join(" ")} 2>/dev/null`
end

describe "openssl_privatekey plugin" do
  it "generates an RSA key in traditional PKCS#1 form with 0600 mode by default" do
    path = key_path("rsa.key")
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})

    result["changed"].as_bool.must_equal(true)
    result["type"].as_s.must_equal("RSA")
    result["size"].as_i.must_equal(2048)
    result["filename"].as_s.must_equal(path)

    File.read(path).lines.first.must_equal("-----BEGIN RSA PRIVATE KEY-----")
    File.info(path).permissions.value.must_equal(0o600)
    key_text(path).must_include("Private-Key: (2048 bit")
  end

  it "is idempotent for an unchanged key" do
    path = key_path("rsa.key")
    seed_key(path, {"size" => "2048"})
    before = File.read(path)
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})

    result["changed"].as_bool.must_equal(false)
    File.read(path).must_equal(before)
  end

  # The real module regenerates on a size or type mismatch under its
  # default regenerate: full_idempotence.
  it "regenerates when the requested size differs" do
    path = key_path("rsa.key")
    seed_key(path, {"size" => "2048"})
    before = File.read(path)
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "3072"})

    result["changed"].as_bool.must_equal(true)
    result["size"].as_i.must_equal(3072)
    File.read(path).wont_equal(before)
    key_text(path).must_include("Private-Key: (3072 bit")
  end

  it "leaves a mismatched key alone with regenerate: never" do
    path = key_path("rsa.key")
    seed_key(path, {"size" => "2048"})
    before = File.read(path)
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "4096", "regenerate" => "never"})

    result["changed"].as_bool.must_equal(false)
    File.read(path).must_equal(before)
  end

  it "fails rather than regenerating with regenerate: fail, using the real module's wording" do
    path = key_path("rsa.key")
    seed_key(path, {"size" => "2048"})
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "4096", "regenerate" => "fail"})

    result["failed"].as_bool.must_equal(true)
    expect(str_starts_with?(result["msg"].as_s, "Key has wrong type and/or size.")).must_equal(true)
  end

  it "generates an ECC key on the requested curve, mapping IANA curve names to OpenSSL's" do
    path = key_path("ec.key")
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "secp256r1"})

    result["changed"].as_bool.must_equal(true)
    result["curve"].as_s.must_equal("secp256r1")
    File.read(path).lines.first.must_equal("-----BEGIN EC PRIVATE KEY-----")
    # secp256r1 is prime256v1 to OpenSSL - genpkey rejects the IANA
    # spelling outright, so an unmapped name would fail here.
    key_text(path).must_include("ASN1 OID: prime256v1")

    rerun = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "secp256r1"})
    rerun["changed"].as_bool.must_equal(false)
  end

  it "regenerates when the curve changes" do
    path = key_path("ec.key")
    seed_key(path, {"type" => "ECC", "curve" => "secp256r1"})
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "secp384r1"})

    result["changed"].as_bool.must_equal(true)
    key_text(path).must_include("ASN1 OID: secp384r1")
  end

  it "rejects an unknown curve with the real module's argspec message" do
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => key_path("nope.key"), "type" => "ECC", "curve" => "nonsense"})

    result["failed"].as_bool.must_equal(true)
    expect(str_starts_with?(result["msg"].as_s, "value of curve must be one of: secp224r1, secp256k1, secp256r1")).must_equal(true)
    expect(str_ends_with?(result["msg"].as_s, "got: nonsense")).must_equal(true)
  end

  it "writes Ed25519 keys as PKCS#8, the only format they have" do
    path = key_path("ed.key")
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "type" => "Ed25519"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).lines.first.must_equal("-----BEGIN PRIVATE KEY-----")

    rerun = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "type" => "Ed25519"})
    rerun["changed"].as_bool.must_equal(false)
  end

  # format: raw is bare key material - no PEM header, not valid UTF-8,
  # and nothing openssl can parse back. Reading it as a String threw and
  # made every rerun regenerate it.
  it "writes and re-recognizes a raw Ed25519 key" do
    path = key_path("raw.key")
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "Ed25519", "format" => "raw"})

    result["changed"].as_bool.must_equal(true)
    File.size(path).must_equal(32)

    rerun = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "Ed25519", "format" => "raw"})
    rerun["changed"].as_bool.must_equal(false)
  end

  it "encrypts with AES-256-CBC when a passphrase is given, and stays idempotent" do
    path = key_path("pw.key")
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "2048", "passphrase" => "s3cret", "cipher" => "auto"})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.must_include("Proc-Type: 4,ENCRYPTED")
    content.must_include("DEK-Info: AES-256-CBC")
    key_text(path, "s3cret").must_include("Private-Key: (2048 bit")

    rerun = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "2048", "passphrase" => "s3cret", "cipher" => "auto"})
    rerun["changed"].as_bool.must_equal(false)
  end

  # Real behavior, verified live: a wrong (or missing, or unexpected)
  # passphrase is NOT a failure under the default regenerate mode - the
  # key is simply regenerated.
  it "regenerates rather than failing when the passphrase does not match" do
    path = key_path("pw.key")
    seed_key(path, {"size" => "2048", "passphrase" => "s3cret", "cipher" => "auto"})
    before = File.read(path)
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "2048", "passphrase" => "different"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).wont_equal(before)
  end

  it "regenerates when a passphrase is dropped from a previously encrypted key" do
    path = key_path("pw.key")
    seed_key(path, {"size" => "2048", "passphrase" => "s3cret", "cipher" => "auto"})
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).wont_include("ENCRYPTED")
  end

  it "does not hold an existing key's format against it by default (auto_ignore)" do
    path = key_path("fmt.key")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048", "format" => "pkcs8"})
    File.read(path).lines.first.must_equal("-----BEGIN PRIVATE KEY-----")

    rerun = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
    rerun["changed"].as_bool.must_equal(false)
    File.read(path).lines.first.must_equal("-----BEGIN PRIVATE KEY-----")
  end

  it "converts instead of regenerating with format_mismatch: convert" do
    path = key_path("conv.key")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
    modulus_before = `openssl rsa -in #{path} -noout -modulus 2>/dev/null`

    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "2048", "format" => "pkcs8", "format_mismatch" => "convert"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).lines.first.must_equal("-----BEGIN PRIVATE KEY-----")
    # Converted, not regenerated: same key material.
    `openssl rsa -in #{path} -noout -modulus 2>/dev/null`.must_equal(modulus_before)

    rerun = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "2048", "format" => "pkcs8", "format_mismatch" => "convert"})
    rerun["changed"].as_bool.must_equal(false)
  end

  it "honours mode, force and backup" do
    path = key_path("attrs.key")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048", "mode" => "0640"})
    File.info(path).permissions.value.must_equal(0o640)

    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "2048", "mode" => "0640", "force" => "true", "backup" => "true"})

    result["changed"].as_bool.must_equal(true)
    backup = result["backup_file"].as_s
    File.exists?(backup).must_equal(true)
    File.read(backup).wont_equal(File.read(path))
  end

  it "returns the key content only when asked" do
    path = key_path("content.key")
    plain = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
    plain["privatekey"]?.must_be_nil

    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "2048", "return_content" => "true"})
    expect(str_starts_with?(result["privatekey"].as_s, "-----BEGIN RSA PRIVATE KEY-----")).must_equal(true)
  end

  # The real module fingerprints the DER SubjectPublicKeyInfo of the
  # public key; verified equal to the real module's own output for the
  # same key file, algorithm by algorithm.
  it "reports public-key fingerprints matching openssl's own digests" do
    path = key_path("fp.key")
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})

    fingerprint = result["fingerprint"].as_h
    %w[md5 sha1 sha224 sha256 sha384 sha512 sha3_256 blake2b blake2s].each do |algorithm|
      fingerprint.has_key?(algorithm).must_equal(true)
    end

    expected = `openssl pkey -in #{path} -pubout -outform DER 2>/dev/null | openssl dgst -sha256 -c`
      .split("= ").last.strip
    fingerprint["sha256"].as_s.must_equal(expected)
  end

  it "removes the key for state: absent and reports no change when already gone" do
    path = key_path("gone.key")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})

    removed = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "state" => "absent"})
    removed["changed"].as_bool.must_equal(true)
    File.exists?(path).must_equal(false)

    again = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "state" => "absent"})
    again["changed"].as_bool.must_equal(false)
  end

  it "reports the change without writing anything in check mode" do
    path = key_path("checkmode.key")
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "size" => "2048", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.exists?(path).must_equal(false)
  end
end
