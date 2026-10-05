require "../minitest_helper"
require "../../src/krikri/plugin_helpers/openssl_pkey"

# Unit tests for the native libcrypto keygen/serialization helper
# (plugin_helpers/openssl_pkey.cr) that backs plugins/openssl_privatekey.cr
# without the `openssl` CLI. All expectations here were checked against
# what real community.crypto.openssl_privatekey produces (PEM headers,
# encryption shape, curve names, bits) - the file-format specifics are
# additionally covered by the integration suite, which diffs against the
# Ansible module's output.
describe "Krikri::PluginHelpers::Pkey" do
  describe "generate" do
    it "generates an RSA key of the requested size" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0)
      pkey.wont_be_nil
      info = Krikri::PluginHelpers::Pkey.info(pkey.not_nil!)
      info.base_nid.must_equal(Krikri::PluginHelpers::Pkey::NID_RSA)
      info.bits.must_equal(2048)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey.not_nil!)
    end

    it "generates an ECC key on the requested curve, OpenSSL short name included" do
      nid = LibCrypto.obj_sn2nid("brainpoolP384r1")
      refute_equal(0, nid)
      pkey = Krikri::PluginHelpers::Pkey.generate("ECC", 0, nid)
      pkey.wont_be_nil
      info = Krikri::PluginHelpers::Pkey.info(pkey.not_nil!)
      info.base_nid.must_equal(Krikri::PluginHelpers::Pkey::NID_EC)
      info.curve_sn.must_equal("brainpoolP384r1")
      info.bits.must_equal(384)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey.not_nil!)
    end

    it "generates an Ed448 key regardless of the size parameter" do
      pkey = Krikri::PluginHelpers::Pkey.generate("Ed448", 29, 0)
      pkey.wont_be_nil
      Krikri::PluginHelpers::Pkey.info(pkey.not_nil!).base_nid.must_equal(Krikri::PluginHelpers::Pkey::NID_ED448)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey.not_nil!)
    end

    it "returns nil for an unknown type" do
      Krikri::PluginHelpers::Pkey.generate("Nonsense", 2048, 0).must_be_nil
    end
  end

  describe "serialize_pem / load" do
    it "writes RSA keys in traditional PKCS#1 form and reads them back" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0).not_nil!
      pem = Krikri::PluginHelpers::Pkey.serialize_pem(pkey, "RSA", "pkcs1", nil)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)
      pem.wont_be_nil
      String.new(pem.not_nil!).lines.first.must_equal("-----BEGIN RSA PRIVATE KEY-----")

      reloaded = Krikri::PluginHelpers::Pkey.load(pem.not_nil!, nil)
      reloaded.wont_be_nil
      info = Krikri::PluginHelpers::Pkey.info(reloaded.not_nil!)
      info.base_nid.must_equal(Krikri::PluginHelpers::Pkey::NID_RSA)
      info.bits.must_equal(2048)
      Krikri::PluginHelpers::Pkey.free_pkey(reloaded.not_nil!)
    end

    it "writes EC keys in traditional form with their curve OID" do
      nid = LibCrypto.obj_sn2nid("secp384r1")
      pkey = Krikri::PluginHelpers::Pkey.generate("ECC", 0, nid).not_nil!
      pem = Krikri::PluginHelpers::Pkey.serialize_pem(pkey, "ECC", "pkcs1", nil)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)
      text = String.new(pem.not_nil!)
      text.lines.first.must_equal("-----BEGIN EC PRIVATE KEY-----")

      reloaded = Krikri::PluginHelpers::Pkey.load(text, nil).not_nil!
      Krikri::PluginHelpers::Pkey.info(reloaded).curve_sn.must_equal("secp384r1")
      Krikri::PluginHelpers::Pkey.free_pkey(reloaded)
    end

    it "encrypts PKCS#1 output with AES-256-CBC when a passphrase is given" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0).not_nil!
      pem = String.new(Krikri::PluginHelpers::Pkey.serialize_pem(pkey, "RSA", "pkcs1", "s3cret").not_nil!)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)
      pem.must_include("Proc-Type: 4,ENCRYPTED")
      pem.must_include("DEK-Info: AES-256-CBC")

      # The right passphrase reads the key back; a wrong one (and no
      # passphrase at all) fails - the idempotency check's mismatch rules
      # depend on this.
      Krikri::PluginHelpers::Pkey.load(pem, "s3cret").wont_be_nil
      Krikri::PluginHelpers::Pkey.load(pem, "wrong").must_be_nil
      Krikri::PluginHelpers::Pkey.load(pem, nil).must_be_nil
    end

    it "encrypts PKCS#8 output for the Edwards types that have no traditional form" do
      pkey = Krikri::PluginHelpers::Pkey.generate("Ed448", 29, 0).not_nil!
      pem = String.new(Krikri::PluginHelpers::Pkey.serialize_pem(pkey, "Ed448", "pkcs8", "rebfhu").not_nil!)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)
      pem.lines.first.must_equal("-----BEGIN ENCRYPTED PRIVATE KEY-----")

      reloaded = Krikri::PluginHelpers::Pkey.load(pem, "rebfhu")
      reloaded.wont_be_nil
      Krikri::PluginHelpers::Pkey.info(reloaded.not_nil!).base_nid.must_equal(Krikri::PluginHelpers::Pkey::NID_ED448)
      Krikri::PluginHelpers::Pkey.free_pkey(reloaded.not_nil!)
      Krikri::PluginHelpers::Pkey.load(pem, "wrong").must_be_nil
    end

    it "returns nil when asked to parse non-key material" do
      Krikri::PluginHelpers::Pkey.load("not a key at all", nil).must_be_nil
    end
  end

  describe "pkcs8_der" do
    it "yields DER whose tail is the raw Edwards key bytes" do
      pkey = Krikri::PluginHelpers::Pkey.generate("Ed25519", 32, 0).not_nil!
      der = Krikri::PluginHelpers::Pkey.pkcs8_der(pkey)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)
      der.wont_be_nil
      (der.not_nil!.size >= 32).must_equal(true)
    end
  end

  describe "public_der" do
    it "yields the SubjectPublicKeyInfo DER the fingerprints hash" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0).not_nil!
      der = Krikri::PluginHelpers::Pkey.public_der(pkey)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)
      der.wont_be_nil
      (der.not_nil!.size > 100).must_equal(true)
      digest = OpenSSL::Digest.new("SHA256")
      digest.update(der.not_nil!)
      digest.final.hexstring.size.must_equal(64)
    end
  end

  # load_checked reproduces `cryptography`'s load_pem_private_key failure
  # semantics - the exact messages the Ansible module's load_privatekey maps
  # onto its fail_json msg (live-diffed vs ansible-playbook 2.19.11,
  # kpg35 sweep #247/#249/#251). The OpenSSLError tuple entries come from
  # libcrypto's own error queue, so they match real byte-for-byte on the
  # same libcrypto the target ships.
  describe "load_checked" do
    GARBAGE = "hpzbar"

    it "fails garbage content with Ansible's unparsable-key message" do
      pkey, failure = Krikri::PluginHelpers::Pkey.load_checked(GARBAGE, "vizpow")
      pkey.must_be_nil
      failure.wont_be_nil
      failure.not_nil!.passphrase_problem.must_equal(false)
      failure.not_nil!.message.must_equal(
        "Wrong passphrase provided for private key, or private key cannot be parsed: " \
        "('Could not deserialize key data. The data may be in an incorrect format, the provided password may be incorrect, it may be encrypted with an unsupported algorithm, or it may be an unsupported key type (e.g. EC curves with explicit parameters).', " \
        "[<OpenSSLError(code=503841036, lib=60, reason=524556, reason_text=unsupported)>])")
    end

    it "fails garbage content without a passphrase with the same message" do
      pkey, failure = Krikri::PluginHelpers::Pkey.load_checked(GARBAGE, nil)
      pkey.must_be_nil
      failure.wont_be_nil
      failure.not_nil!.passphrase_problem.must_equal(false)
      failure.not_nil!.message.must_include("Wrong passphrase provided for private key, or private key cannot be parsed:")
      failure.not_nil!.message.must_include("Could not deserialize key data.")
      failure.not_nil!.message.must_include("<OpenSSLError(code=503841036, lib=60, reason=524556, reason_text=unsupported)>")
    end

    it "reports the passphrase-mismatch branch for a password on an unencrypted key" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0).not_nil!
      pem = String.new(Krikri::PluginHelpers::Pkey.serialize_pem(pkey, "RSA", "pkcs1", nil).not_nil!)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)

      pkey2, failure = Krikri::PluginHelpers::Pkey.load_checked(pem, "notused")
      pkey2.must_be_nil
      failure.wont_be_nil
      failure.not_nil!.passphrase_problem.must_equal(true)
      failure.not_nil!.message.must_equal("Wrong or empty passphrase provided for private key")
    end

    it "reports the passphrase-mismatch branch for a missing password on an encrypted key" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0).not_nil!
      pem = String.new(Krikri::PluginHelpers::Pkey.serialize_pem(pkey, "RSA", "pkcs1", "s3cret").not_nil!)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)

      pkey2, failure = Krikri::PluginHelpers::Pkey.load_checked(pem, nil)
      pkey2.must_be_nil
      failure.wont_be_nil
      failure.not_nil!.passphrase_problem.must_equal(true)
      failure.not_nil!.message.must_equal("Wrong or empty passphrase provided for private key")
    end

    it "fails a wrong passphrase with the bad-decrypt error queue" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0).not_nil!
      pem = String.new(Krikri::PluginHelpers::Pkey.serialize_pem(pkey, "RSA", "pkcs1", "s3cret").not_nil!)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)

      pkey2, failure = Krikri::PluginHelpers::Pkey.load_checked(pem, "wrong")
      pkey2.must_be_nil
      failure.wont_be_nil
      failure.not_nil!.passphrase_problem.must_equal(false)
      failure.not_nil!.message.must_equal(
        "Wrong passphrase provided for private key, or private key cannot be parsed: " \
        "('Could not deserialize key data. The data may be in an incorrect format, the provided password may be incorrect, it may be encrypted with an unsupported algorithm, or it may be an unsupported key type (e.g. EC curves with explicit parameters).', " \
        "[<OpenSSLError(code=478150756, lib=57, reason=100, reason_text=bad decrypt)>, <OpenSSLError(code=75497573, lib=9, reason=101, reason_text=bad decrypt)>])")
    end

    it "loads an encrypted key with its correct passphrase" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0).not_nil!
      pem = String.new(Krikri::PluginHelpers::Pkey.serialize_pem(pkey, "RSA", "pkcs1", "s3cret").not_nil!)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)

      pkey2, failure = Krikri::PluginHelpers::Pkey.load_checked(pem, "s3cret")
      failure.must_be_nil
      pkey2.wont_be_nil
      Krikri::PluginHelpers::Pkey.info(pkey2.not_nil!).bits.must_equal(2048)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey2.not_nil!)
    end

    it "loads an unencrypted key with no passphrase" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0).not_nil!
      pem = String.new(Krikri::PluginHelpers::Pkey.serialize_pem(pkey, "RSA", "pkcs1", nil).not_nil!)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)

      pkey2, failure = Krikri::PluginHelpers::Pkey.load_checked(pem, nil)
      failure.must_be_nil
      pkey2.wont_be_nil
      Krikri::PluginHelpers::Pkey.free_pkey(pkey2.not_nil!)
    end
  end

  describe "public_pem / load_public" do
    it "round-trips the SubjectPublicKeyInfo PEM of a private key's public half" do
      pkey = Krikri::PluginHelpers::Pkey.generate("RSA", 2048, 0).not_nil!
      pem = String.new(Krikri::PluginHelpers::Pkey.public_pem(pkey).not_nil!)
      der = Krikri::PluginHelpers::Pkey.public_der(pkey)
      Krikri::PluginHelpers::Pkey.free_pkey(pkey)

      pem.starts_with?("-----BEGIN PUBLIC KEY-----").must_equal(true)
      reloaded = Krikri::PluginHelpers::Pkey.load_public(pem)
      reloaded.wont_be_nil
      Krikri::PluginHelpers::Pkey.public_der(reloaded.not_nil!).must_equal(der)
      Krikri::PluginHelpers::Pkey.free_pkey(reloaded.not_nil!)
    end

    it "returns nil for non-public-key material" do
      Krikri::PluginHelpers::Pkey.load_public("not a key").must_be_nil
    end
  end
end
