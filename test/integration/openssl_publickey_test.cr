require "../minitest_helper"
require "file_utils"

# community.crypto.openssl_publickey - derives a public key from a
# private key. Idempotency and result shape matched against the real
# module (community.crypto 3.1.1): content comparison (canonicalized
# here, byte-exact there), OpenSSH format support, fingerprint of the
# DER public key, return_content, backup.

# The classic suite pre-created a shared spec/tmp root in before_suite;
# every test now gets its own tmp_path subtree.
describe "openssl_publickey plugin" do
  it "writes a PEM public key derived from a private key" do
    key = PluginSpecHelper.tmp_path("rsa.key")
    pub = PluginSpecHelper.tmp_path("rsa.pub")
    `openssl genrsa -out #{key} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_publickey", {"path" => pub, "privatekey_path" => key})

    result["changed"].as_bool.must_equal(true)
    result["format"].as_s.must_equal("PEM")
    result["filename"].as_s.must_equal(pub)
    result["privatekey"].as_s.must_equal(key)
    File.read(pub).must_include("-----BEGIN PUBLIC KEY-----")
    result["fingerprint"].as_h["sha256"].as_s.must_match(/^(..:){31}..$/)
  end

  it "is idempotent for an unchanged key" do
    key = PluginSpecHelper.tmp_path("rsa.key")
    pub = PluginSpecHelper.tmp_path("rsa.pub")
    `openssl genrsa -out #{key} 2048 2>/dev/null`
    PluginSpecHelper.run("openssl_publickey", {"path" => pub, "privatekey_path" => key})

    result = PluginSpecHelper.run("openssl_publickey", {"path" => pub, "privatekey_path" => key})

    result["changed"].as_bool.must_equal(false)
    # No return_content -> no publickey field at all.
    result["publickey"]?.must_be_nil
  end

  it "regenerates when the private key changes" do
    key = PluginSpecHelper.tmp_path("rsa.key")
    pub = PluginSpecHelper.tmp_path("rsa.pub")
    `openssl genrsa -out #{key} 2048 2>/dev/null`
    PluginSpecHelper.run("openssl_publickey", {"path" => pub, "privatekey_path" => key})
    before = File.read(pub)
    `openssl genrsa -out #{key} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_publickey",
      {"path" => pub, "privatekey_path" => key, "return_content" => "true"})

    result["changed"].as_bool.must_equal(true)
    result["publickey"].as_s.must_include("-----BEGIN PUBLIC KEY-----")
    result["publickey"].as_s.wont_equal(before)
  end

  it "writes an OpenSSH-format public key" do
    key = PluginSpecHelper.tmp_path("rsa.key")
    pub = PluginSpecHelper.tmp_path("rsa-ssh.pub")
    `openssl genrsa -out #{key} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_publickey",
      {"path" => pub, "privatekey_path" => key, "format" => "OpenSSH"})

    result["changed"].as_bool.must_equal(true)
    result["format"].as_s.must_equal("OpenSSH")
    File.read(pub).must_match(/^ssh-rsa /)
  end

  it "removes the file with state: absent (and reports it absent on rerun)" do
    key = PluginSpecHelper.tmp_path("rsa.key")
    pub = PluginSpecHelper.tmp_path("absent.pub")
    `openssl genrsa -out #{key} 2048 2>/dev/null`
    File.write(pub, "x")

    result = PluginSpecHelper.run("openssl_publickey",
      {"path" => pub, "privatekey_path" => key, "state" => "absent"})

    result["changed"].as_bool.must_equal(true)
    File.exists?(pub).must_equal(false)

    rerun = PluginSpecHelper.run("openssl_publickey",
      {"path" => pub, "privatekey_path" => key, "state" => "absent"})
    rerun["changed"].as_bool.must_equal(false)
  end

  it "fails when the private key is missing" do
    result = PluginSpecHelper.run("openssl_publickey",
      {"path"            => PluginSpecHelper.tmp_path("orphan.pub"),
       "privatekey_path" => PluginSpecHelper.tmp_path("nope.key")})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("does not exist")
  end

  # kpg35 sweep #247/#249/#251: the real module loads the key through
  # `cryptography` (byte-for-byte the message below); krikri used to
  # shell out to the openssl CLI, which the target container does not
  # ship. The message is produced natively by the shared Pkey helper
  # (unit-tested in openssl_pkey_helper_test.cr); this pins the plugin's
  # own wiring for both the content and the no-passphrase variants.
  it "fails unparsable privatekey_content with real's exact message" do
    result = PluginSpecHelper.run("openssl_publickey", {
      "path"                  => PluginSpecHelper.tmp_path("garbage.pub"),
      "privatekey_content"    => "hpzbar",
      "privatekey_passphrase" => "vizpow",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(
      "Wrong passphrase provided for private key, or private key cannot be parsed: " \
      "('Could not deserialize key data. The data may be in an incorrect format, the provided password may be incorrect, it may be encrypted with an unsupported algorithm, or it may be an unsupported key type (e.g. EC curves with explicit parameters).', " \
      "[<OpenSSLError(code=503841036, lib=60, reason=524556, reason_text=unsupported)>])")
  end

  it "fails unparsable privatekey_content without a passphrase with the same message" do
    result = PluginSpecHelper.run("openssl_publickey", {
      "path"               => PluginSpecHelper.tmp_path("garbage2.pub"),
      "privatekey_content" => "ydnbbj",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.starts_with?("Wrong passphrase provided for private key, or private key cannot be parsed:").must_equal(true)
    result["msg"].as_s.must_include("<OpenSSLError(code=503841036, lib=60, reason=524556, reason_text=unsupported)>")
  end

  it "fails a passphrase on an unencrypted key with the mismatch message" do
    key = PluginSpecHelper.tmp_path("plain.key")
    `openssl genrsa -out #{key} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_publickey", {
      "path"                  => PluginSpecHelper.tmp_path("mismatch.pub"),
      "privatekey_path"       => key,
      "privatekey_passphrase" => "notused",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Wrong or empty passphrase provided for private key")
  end
end
