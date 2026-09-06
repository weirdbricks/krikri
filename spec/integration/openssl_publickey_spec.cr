require "../spec_helper"
require "file_utils"

# community.crypto.openssl_publickey - derives a public key from a
# private key. Idempotency and result shape matched against the real
# module (community.crypto 3.1.1): content comparison (canonicalized
# here, byte-exact there), OpenSSH format support, fingerprint of the
# DER public key, return_content, backup.
private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "openssl_publickey")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

describe "openssl_publickey plugin" do
  it "writes a PEM public key derived from a private key" do
    key = File.join(TMP_DIR, "rsa.key")
    pub = File.join(TMP_DIR, "rsa.pub")
    `openssl genrsa -out #{key} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_publickey", {"path" => pub, "privatekey_path" => key})

    result["changed"].as_bool.should be_true
    result["format"].as_s.should eq("PEM")
    result["filename"].as_s.should eq(pub)
    result["privatekey"].as_s.should eq(key)
    File.read(pub).should contain("-----BEGIN PUBLIC KEY-----")
    result["fingerprint"].as_h["sha256"].as_s.should match(/^(..:){31}..$/)
  end

  it "is idempotent for an unchanged key" do
    key = File.join(TMP_DIR, "rsa.key")
    pub = File.join(TMP_DIR, "rsa.pub")

    result = PluginSpecHelper.run("openssl_publickey", {"path" => pub, "privatekey_path" => key})

    result["changed"].as_bool.should be_false
    # No return_content -> no publickey field at all.
    result["publickey"]?.should be_nil
  end

  it "regenerates when the private key changes" do
    key = File.join(TMP_DIR, "rsa.key")
    pub = File.join(TMP_DIR, "rsa.pub")
    before = File.read(pub)
    `openssl genrsa -out #{key} 2048 2>/dev/null`

    result = PluginSpecHelper.run("openssl_publickey",
      {"path" => pub, "privatekey_path" => key, "return_content" => "true"})

    result["changed"].as_bool.should be_true
    result["publickey"].as_s.should contain("-----BEGIN PUBLIC KEY-----")
    result["publickey"].as_s.should_not eq(before)
  end

  it "writes an OpenSSH-format public key" do
    key = File.join(TMP_DIR, "rsa.key")
    pub = File.join(TMP_DIR, "rsa-ssh.pub")

    result = PluginSpecHelper.run("openssl_publickey",
      {"path" => pub, "privatekey_path" => key, "format" => "OpenSSH"})

    result["changed"].as_bool.should be_true
    result["format"].as_s.should eq("OpenSSH")
    File.read(pub).should match(/^ssh-rsa /)
  end

  it "removes the file with state: absent (and reports it absent on rerun)" do
    key = File.join(TMP_DIR, "rsa.key")
    pub = File.join(TMP_DIR, "absent.pub")
    File.write(pub, "x")

    result = PluginSpecHelper.run("openssl_publickey",
      {"path" => pub, "privatekey_path" => key, "state" => "absent"})

    result["changed"].as_bool.should be_true
    File.exists?(pub).should be_false

    rerun = PluginSpecHelper.run("openssl_publickey",
      {"path" => pub, "privatekey_path" => key, "state" => "absent"})
    rerun["changed"].as_bool.should be_false
  end

  it "fails when the private key is missing" do
    result = PluginSpecHelper.run("openssl_publickey",
      {"path"            => File.join(TMP_DIR, "orphan.pub"),
       "privatekey_path" => File.join(TMP_DIR, "nope.key")})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("does not exist")
  end
end
