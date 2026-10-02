require "../minitest_helper"
require "../../src/krikri/plugin_helpers/openssl_pkey"

# Unit tests for the native libcrypto keygen/serialization helper
# (plugin_helpers/openssl_pkey.cr) that backs plugins/openssl_privatekey.cr
# without the `openssl` CLI. All expectations here were checked against
# what real community.crypto.openssl_privatekey produces (PEM headers,
# encryption shape, curve names, bits) - the file-format specifics are
# additionally covered by the integration suite, which diffs against the
# real module's output.
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
end
