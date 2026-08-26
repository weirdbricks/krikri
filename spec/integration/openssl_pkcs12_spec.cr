require "../spec_helper"
require "file_utils"

# community.crypto.openssl_pkcs12 (action: export), differentialed
# against the real module (community.crypto 3.1.1 / ansible-core
# 2.19.4) - including its unusually tight 0400 default mode and the
# fact that an unchanged export must not rewrite the (salted, never
# byte-identical) archive.
private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "openssl_pkcs12")

private def path_for(name : String) : String
  File.join(TMP_DIR, name)
end

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)

  PluginSpecHelper.run("openssl_privatekey", {"path" => path_for("a.key"), "size" => "2048"})
  PluginSpecHelper.run("openssl_csr",
    {"path" => path_for("a.csr"), "privatekey_path" => path_for("a.key"), "common_name" => "p12.example.com"})
  PluginSpecHelper.run("x509_certificate",
    {"path" => path_for("a.crt"), "privatekey_path" => path_for("a.key"),
     "csr_path" => path_for("a.csr"), "provider" => "selfsigned"})
end

private def export_params(name : String, extra = {} of String => String)
  params = {
    "action"           => "export",
    "path"             => path_for("a.p12"),
    "friendly_name"    => name,
    "privatekey_path"  => path_for("a.key"),
    "certificate_path" => path_for("a.crt"),
    "state"            => "present",
  }
  extra.each { |k, v| params[k] = v }
  params
end

describe "openssl_pkcs12 plugin" do
  it "exports a bundle of the key and certificate, 0400 by default" do
    result = PluginSpecHelper.run("openssl_pkcs12", export_params("myname"))

    result["changed"].as_bool.should be_true
    result["filename"].as_s.should eq(path_for("a.p12"))
    result["privatekey_path"].as_s.should eq(path_for("a.key"))
    result["mode"].as_s.should eq("0400")
    File.info(path_for("a.p12")).permissions.value.should eq(0o400)

    dump = `openssl pkcs12 -in #{path_for("a.p12")} -nodes -passin pass: 2>/dev/null`
    dump.should contain("friendlyName: myname")
    dump.should contain("-----BEGIN CERTIFICATE-----")
  end

  it "is idempotent even though every export is salted differently" do
    before = File.read(path_for("a.p12"))
    result = PluginSpecHelper.run("openssl_pkcs12", export_params("myname"))

    result["changed"].as_bool.should be_false
    File.read(path_for("a.p12")).should eq(before)
  end

  it "re-exports when the friendly name changes" do
    result = PluginSpecHelper.run("openssl_pkcs12", export_params("othername"))

    result["changed"].as_bool.should be_true
    `openssl pkcs12 -in #{path_for("a.p12")} -nodes -passin pass: 2>/dev/null`
      .should contain("friendlyName: othername")
  end

  it "re-exports when the certificate changes" do
    PluginSpecHelper.run("x509_certificate",
      {"path" => path_for("a.crt"), "privatekey_path" => path_for("a.key"),
       "csr_path" => path_for("a.csr"), "provider" => "selfsigned", "force" => "true"})

    result = PluginSpecHelper.run("openssl_pkcs12", export_params("othername"))
    result["changed"].as_bool.should be_true
  end

  it "encrypts with a passphrase and stays idempotent behind it" do
    params = export_params("pw", {"path" => path_for("b.p12"), "passphrase" => "p12secret"})
    result = PluginSpecHelper.run("openssl_pkcs12", params)
    result["changed"].as_bool.should be_true

    # Readable with the passphrase, not without it.
    `openssl pkcs12 -in #{path_for("b.p12")} -nodes -passin pass:p12secret 2>/dev/null`
      .should contain("-----BEGIN CERTIFICATE-----")
    `openssl pkcs12 -in #{path_for("b.p12")} -nodes -passin pass:wrong 2>/dev/null`.should eq("")

    PluginSpecHelper.run("openssl_pkcs12", params)["changed"].as_bool.should be_false
  end

  it "honours an explicit mode over the 0400 default" do
    params = export_params("moded", {"path" => path_for("c.p12"), "mode" => "0640"})
    PluginSpecHelper.run("openssl_pkcs12", params)
    File.info(path_for("c.p12")).permissions.value.should eq(0o640)
  end

  it "removes the archive for state: absent" do
    removed = PluginSpecHelper.run("openssl_pkcs12", {"path" => path_for("c.p12"), "state" => "absent"})
    removed["changed"].as_bool.should be_true
    File.exists?(path_for("c.p12")).should be_false
    PluginSpecHelper.run("openssl_pkcs12",
      {"path" => path_for("c.p12"), "state" => "absent"})["changed"].as_bool.should be_false
  end

  it "rejects action: parse rather than silently doing nothing" do
    result = PluginSpecHelper.run("openssl_pkcs12",
      {"action" => "parse", "path" => path_for("a.p12"), "privatekey_path" => path_for("a.key")})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("not supported")
  end
end
