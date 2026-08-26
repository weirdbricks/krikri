require "../spec_helper"
require "file_utils"

# community.crypto.x509_certificate, providers selfsigned and ownca.
# Behavior differentialed against the real module (community.crypto
# 3.1.1 / ansible-core 2.19.4), including its extension output
# (SubjectKeyIdentifier always, AuthorityKeyIdentifier for ownca) and
# its idempotency rules - a certificate carries a random serial and
# fresh timestamps, so "unchanged" can never mean "same bytes".
private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "x509_certificate")

private def path_for(name : String) : String
  File.join(TMP_DIR, name)
end

private def make_key(name : String) : String
  path = path_for(name)
  PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
  path
end

private def make_csr(name : String, key : String, common_name : String, extra = {} of String => String) : String
  path = path_for(name)
  params = {"path" => path, "privatekey_path" => key, "common_name" => common_name}
  extra.each { |k, v| params[k] = v }
  PluginSpecHelper.run("openssl_csr", params)
  path
end

private def cert_text(path : String) : String
  `openssl x509 -in #{path} -noout -text 2>/dev/null`
end

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

describe "x509_certificate plugin" do
  it "issues a self-signed certificate from a CSR, valid for ten years" do
    key = make_key("a.key")
    csr = make_csr("a.csr", key, "self.example.com")
    path = path_for("a.crt")

    result = PluginSpecHelper.run("x509_certificate",
      {"path" => path, "privatekey_path" => key, "csr_path" => csr, "provider" => "selfsigned"})

    result["changed"].as_bool.should be_true
    result["filename"].as_s.should eq(path)
    result["csr"].as_s.should eq(csr)
    result["notBefore"].as_s.should match(/\A\d{14}Z\z/)
    result["serial_number"].as_i64.should be > 0

    `openssl x509 -in #{path} -noout -subject 2>/dev/null`.strip.should eq("subject=CN=self.example.com")
    `openssl x509 -in #{path} -noout -issuer 2>/dev/null`.strip.should eq("issuer=CN=self.example.com")

    # ~10 years out, matching selfsigned_not_after's "+3650d" default.
    days = (Time.parse_utc(result["notAfter"].as_s, "%Y%m%d%H%M%SZ") - Time.utc).total_days
    days.should be_close(3650, 2)
  end

  # The CSR's extensions have to survive into the certificate, and a
  # SubjectKeyIdentifier is added on top - the real module's output
  # exactly.
  it "copies the CSR's extensions and adds a subject key identifier" do
    key = make_key("ext.key")
    csr = make_csr("ext.csr", key, "ext.example.com",
      {"subject_alt_name" => %(["DNS:ext.example.com","DNS:alt.example.com"]),
       "key_usage" => %(["digitalSignature"])})
    path = path_for("ext.crt")

    PluginSpecHelper.run("x509_certificate",
      {"path" => path, "privatekey_path" => key, "csr_path" => csr, "provider" => "selfsigned"})

    text = cert_text(path)
    text.should contain("DNS:ext.example.com, DNS:alt.example.com")
    text.should contain("Digital Signature")
    text.should contain("X509v3 Subject Key Identifier")
  end

  it "is idempotent despite the random serial and fresh timestamps" do
    key = path_for("a.key")
    csr = path_for("a.csr")
    path = path_for("a.crt")
    before = File.read(path)

    result = PluginSpecHelper.run("x509_certificate",
      {"path" => path, "privatekey_path" => key, "csr_path" => csr, "provider" => "selfsigned"})

    result["changed"].as_bool.should be_false
    File.read(path).should eq(before)
  end

  it "reissues when the CSR's subject changes" do
    key = path_for("a.key")
    csr = make_csr("a.csr", key, "renamed.example.com")
    path = path_for("a.crt")

    result = PluginSpecHelper.run("x509_certificate",
      {"path" => path, "privatekey_path" => key, "csr_path" => csr, "provider" => "selfsigned"})

    result["changed"].as_bool.should be_true
    `openssl x509 -in #{path} -noout -subject 2>/dev/null`.strip.should eq("subject=CN=renamed.example.com")
  end

  it "reissues when the private key no longer matches the certificate" do
    new_key = make_key("a2.key")
    csr = make_csr("a.csr", new_key, "renamed.example.com")
    path = path_for("a.crt")

    result = PluginSpecHelper.run("x509_certificate",
      {"path" => path, "privatekey_path" => new_key, "csr_path" => csr, "provider" => "selfsigned"})
    result["changed"].as_bool.should be_true
  end

  it "signs with an own CA, recording the CA as issuer and adding an authority key identifier" do
    ca_key = make_key("ca.key")
    ca_csr = make_csr("ca.csr", ca_key, "My CA",
      {"basic_constraints" => %(["CA:TRUE"]), "basic_constraints_critical" => "true",
       "key_usage" => %(["keyCertSign"])})
    ca_crt = path_for("ca.crt")
    PluginSpecHelper.run("x509_certificate",
      {"path" => ca_crt, "privatekey_path" => ca_key, "csr_path" => ca_csr, "provider" => "selfsigned"})

    leaf_key = make_key("leaf.key")
    leaf_csr = make_csr("leaf.csr", leaf_key, "leaf.example.com")
    leaf_crt = path_for("leaf.crt")

    result = PluginSpecHelper.run("x509_certificate",
      {"path" => leaf_crt, "csr_path" => leaf_csr, "ownca_path" => ca_crt,
       "ownca_privatekey_path" => ca_key, "provider" => "ownca"})

    result["changed"].as_bool.should be_true
    `openssl x509 -in #{leaf_crt} -noout -issuer 2>/dev/null`.strip.should eq("issuer=CN=My CA")
    cert_text(leaf_crt).should contain("X509v3 Authority Key Identifier")
    `openssl verify -CAfile #{ca_crt} #{leaf_crt} 2>&1`.should contain("OK")

    rerun = PluginSpecHelper.run("x509_certificate",
      {"path" => leaf_crt, "csr_path" => leaf_csr, "ownca_path" => ca_crt,
       "ownca_privatekey_path" => ca_key, "provider" => "ownca"})
    rerun["changed"].as_bool.should be_false
  end

  # The case a subject comparison alone cannot see: the CA is rebuilt
  # under the same name, so every certificate it signed is now
  # unverifiable and has to be reissued. Caught via the authority key
  # identifier, which is what the real module compares too.
  it "reissues when the CA is regenerated under the same subject name" do
    ca_key = path_for("ca.key")
    ca_crt = path_for("ca.crt")
    PluginSpecHelper.run("openssl_privatekey", {"path" => ca_key, "size" => "2048", "force" => "true"})
    ca_csr = make_csr("ca.csr", ca_key, "My CA",
      {"basic_constraints" => %(["CA:TRUE"]), "basic_constraints_critical" => "true",
       "key_usage" => %(["keyCertSign"])})
    PluginSpecHelper.run("x509_certificate",
      {"path" => ca_crt, "privatekey_path" => ca_key, "csr_path" => ca_csr,
       "provider" => "selfsigned", "force" => "true"})

    result = PluginSpecHelper.run("x509_certificate",
      {"path" => path_for("leaf.crt"), "csr_path" => path_for("leaf.csr"), "ownca_path" => ca_crt,
       "ownca_privatekey_path" => ca_key, "provider" => "ownca"})

    result["changed"].as_bool.should be_true
    `openssl verify -CAfile #{ca_crt} #{path_for("leaf.crt")} 2>&1`.should contain("OK")
  end

  it "honours a relative not_after other than the default" do
    key = path_for("a.key")
    csr = path_for("a.csr")
    path = path_for("shortlived.crt")

    result = PluginSpecHelper.run("x509_certificate",
      {"path" => path, "privatekey_path" => key, "csr_path" => csr, "provider" => "selfsigned",
       "selfsigned_not_after" => "+30d"})

    days = (Time.parse_utc(result["notAfter"].as_s, "%Y%m%d%H%M%SZ") - Time.utc).total_days
    days.should be_close(30, 2)
  end

  it "leaves permissions to the umask unless mode is given" do
    key = path_for("a.key")
    csr = path_for("a.csr")
    path = path_for("perm.crt")

    PluginSpecHelper.run("x509_certificate",
      {"path" => path, "privatekey_path" => key, "csr_path" => csr, "provider" => "selfsigned"})
    umask = `umask`.strip.to_i(8)
    File.info(path).permissions.value.should eq(0o666 & ~umask)
  end

  it "removes the certificate for state: absent" do
    path = path_for("perm.crt")
    removed = PluginSpecHelper.run("x509_certificate", {"path" => path, "state" => "absent"})
    removed["changed"].as_bool.should be_true
    File.exists?(path).should be_false
    PluginSpecHelper.run("x509_certificate", {"path" => path, "state" => "absent"})["changed"].as_bool.should be_false
  end

  it "rejects providers it does not implement instead of pretending" do
    result = PluginSpecHelper.run("x509_certificate",
      {"path" => path_for("acme.crt"), "csr_path" => path_for("a.csr"), "provider" => "acme"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("not supported")
  end
end
