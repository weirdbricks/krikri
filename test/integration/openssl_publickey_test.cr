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

  # kpg35 sweep #247/#249/#251: the Ansible module loads the key through
  # `cryptography` (byte-for-byte the message below); krikri used to
  # shell out to the openssl CLI, which the target container does not
  # ship. The message is produced natively by the shared Pkey helper
  # (unit-tested in openssl_pkey_helper_test.cr); this pins the plugin's
  # own wiring for both the content and the no-passphrase variants.
  it "fails unparsable privatekey_content with Ansible's exact message" do
    result = PluginSpecHelper.run("openssl_publickey", {
      "path"                  => PluginSpecHelper.tmp_path("garbage.pub"),
      "privatekey_content"    => "hpzbar",
      "privatekey_passphrase" => "vizpow",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(
      "Wrong passphrase provided for private key, or private key cannot be parsed: " \
      "Unable to load PEM file. See https://cryptography.io/en/latest/faq/#why-can-t-i-import-my-pem-file for more details. MalformedFraming")
  end

  it "fails unparsable privatekey_content without a passphrase with the same message" do
    result = PluginSpecHelper.run("openssl_publickey", {
      "path"               => PluginSpecHelper.tmp_path("garbage2.pub"),
      "privatekey_content" => "ydnbbj",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.starts_with?("Wrong passphrase provided for private key, or private key cannot be parsed:").must_equal(true)
    result["msg"].as_s.must_include("MalformedFraming")
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

  # kpg #1317: Ansible's check-mode branch exits before generate(), so a
  # missing private key only means "the public key is not there yet" -
  # it is reported as a change, never as a failure.
  it "reports a change in check mode when the private key is missing" do
    pub = PluginSpecHelper.tmp_path("check-orphan.pub")

    result = PluginSpecHelper.run("openssl_publickey", {
      "path"                  => pub,
      "privatekey_path"       => PluginSpecHelper.tmp_path("nope.key"),
      "format"                => "OpenSSH",
      "privatekey_passphrase" => "guagri",
      "_ansible_check_mode"   => "true",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    File.exists?(pub).must_equal(false)
  end

  # #1634: the real module's check() returns False (a plain change) as soon
  # as the existing file is not a parsable public key, before it ever loads
  # the private key - so an unparsable private key must not fail check mode.
  it "reports a change in check mode when the current public key is unparsable" do
    key = PluginSpecHelper.tmp_path("broken.key")
    pub = PluginSpecHelper.tmp_path("broken.pub")
    File.write(key, "not a private key\n")
    File.write(pub, "kpg locked dest\nsecond line\n")

    result = PluginSpecHelper.run("openssl_publickey", {
      "path"                  => pub,
      "privatekey_path"       => key,
      "privatekey_passphrase" => "vfhpng",
      "_ansible_check_mode"   => "true",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
  end

  it "compares against the public key that is already there in check mode" do
    key = PluginSpecHelper.tmp_path("check.key")
    pub = PluginSpecHelper.tmp_path("check.pub")
    `openssl genrsa -out #{key} 2048 2>/dev/null`
    PluginSpecHelper.run("openssl_publickey", {"path" => pub, "privatekey_path" => key})

    same = PluginSpecHelper.run("openssl_publickey", {
      "path"                => pub,
      "privatekey_path"     => key,
      "_ansible_check_mode" => "true",
    })

    same["changed"].as_bool.must_equal(false)

    forced = PluginSpecHelper.run("openssl_publickey", {
      "path"                => pub,
      "privatekey_path"     => key,
      "force"               => "true",
      "_ansible_check_mode" => "true",
    })

    forced["changed"].as_bool.must_equal(true)
  end

  # #1633: PublicKey.dump() runs before check(), so the registered result
  # carries the empty fingerprint/diff from construction plus the content
  # of the file that is there right now, even when it is not a key.
  it "reports the construction-time fingerprint, diff and current content in check mode" do
    key = PluginSpecHelper.tmp_path("shape.key")
    pub = PluginSpecHelper.tmp_path("shape.pub")
    File.write(key, "kpg locked dest\nsecond line\n")
    File.write(pub, "kpg locked dest\nsecond line\n")

    result = PluginSpecHelper.run("openssl_publickey", {
      "path"                  => pub,
      "privatekey_path"       => key,
      "privatekey_passphrase" => "vfhpng",
      "return_content"        => "true",
      "_ansible_check_mode"   => "true",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    result["fingerprint"].as_h.empty?.must_equal(true)
    result["publickey"].as_s.must_equal("kpg locked dest\nsecond line\n")
    result["diff"].as_h["before"].as_h.empty?.must_equal(true)
    result["diff"].as_h["after"].as_h.empty?.must_equal(true)
  end

  it "reports a null publickey in check mode when the file is missing and return_content is set" do
    result = PluginSpecHelper.run("openssl_publickey", {
      "path"                  => PluginSpecHelper.tmp_path("absent-check.pub"),
      "privatekey_path"       => PluginSpecHelper.tmp_path("absent-check.key"),
      "privatekey_passphrase" => "vfhpng",
      "return_content"        => "true",
      "_ansible_check_mode"   => "true",
    })

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    result["fingerprint"].as_h.empty?.must_equal(true)
    result["publickey"].raw.must_be_nil
  end
end
