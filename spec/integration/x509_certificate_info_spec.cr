require "../spec_helper"
require "file_utils"

# community.crypto.x509_certificate_info - read-only certificate facts.
# Field shapes verified against the real module (community.crypto 3.1.1,
# ansible-core 2.19.4) rather than the docs: same vocabulary (OpenSSL LN
# names through cryptography's OID table), same sorted list extensions,
# same ASN.1 TIME validity spelling, same colon-hex fingerprints.
private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "x509_certificate_info")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def cert_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "x509_certificate_info plugin" do
  it "reports subject, issuer, validity, serial and version for a self-signed cert" do
    path = cert_path("basic.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{TMP_DIR}/basic.key -out #{path} -days 30 -nodes -subj "/CN=www.example.com/O=Test Org" 2>/dev/null`

    result = PluginSpecHelper.run("x509_certificate_info", {"path" => path})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["version"].as_i.should eq(3)
    result["subject"].as_h["commonName"].as_s.should eq("www.example.com")
    result["subject"].as_h["organizationName"].as_s.should eq("Test Org")
    result["subject_ordered"].as_a[0].as_a[0].as_s.should eq("commonName")
    result["issuer"].as_h["commonName"].as_s.should eq("www.example.com")
    result["signature_algorithm"].as_s.should eq("sha256WithRSAEncryption")
    result["expired"].as_bool.should be_false
    # ASN.1 TIME spelling, both ends.
    result["not_before"].as_s.should match(/^\d{14}Z$/)
    result["not_after"].as_s.should match(/^\d{14}Z$/)
    result["public_key_type"].as_s.should eq("RSA")
    result["public_key_data"].as_h["exponent"].as_i.should eq(65537)
    result["public_key_data"].as_h["size"].as_i.should eq(2048)
  end

  it "parses the extension set: basic constraints, key usage, extended key usage, SAN" do
    path = cert_path("exts.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{TMP_DIR}/exts.key -out #{path} -days 30 -nodes \
      -subj "/CN=exts.example.com" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=serverAuth" \
      -addext "subjectAltName=DNS:www.example.com,IP:1.2.3.4" 2>/dev/null`

    result = PluginSpecHelper.run("x509_certificate_info", {"path" => path})

    result["basic_constraints"].as_a.should eq(["CA:TRUE"])
    result["basic_constraints_critical"].as_bool.should be_true
    # The real module sorts the key usage entries and joins them into one
    # string; "Key Encipherment" sorts before "Digital Signature".
    result["key_usage"].as_s.should eq("Digital Signature, Key Encipherment")
    result["key_usage_critical"].as_bool.should be_false
    result["extended_key_usage"].as_a.should eq(["TLS Web Server Authentication"])
    # The real module renders SAN IP entries as "IP:...", not openssl's
    # "IP Address:..." spelling.
    result["subject_alt_name"].as_a.map(&.as_s).should eq(["DNS:www.example.com", "IP:1.2.3.4"])
  end

  it "reports expired for a cert whose notAfter is in the past" do
    path = cert_path("expired.pem")
    # openssl req rejects non-positive -days, so backdate with -not_after
    # (OpenSSL 3) when available; a missing file means the local openssl
    # can't backdate and this environment can't test the flag.
    `openssl req -x509 -newkey rsa:2048 -keyout #{TMP_DIR}/expired.key -out #{path} -nodes -subj "/CN=old.example.com" -not_after 20200101000000Z 2>/dev/null`
    unless File.exists?(path)
      puts "skipping: openssl lacks -not_after; cannot backdate a certificate"
      next
    end

    result = PluginSpecHelper.run("x509_certificate_info", {"path" => path})

    result["expired"].as_bool.should be_true
  end

  it "fails for a missing path, and for path+content given together" do
    result = PluginSpecHelper.run("x509_certificate_info", {"path" => File.join(TMP_DIR, "nope.pem")})
    result["failed"].as_bool.should be_true

    result = PluginSpecHelper.run("x509_certificate_info",
      {"path" => "/dev/null", "content" => "-----BEGIN CERTIFICATE-----"})
    result["failed"].as_bool.should be_true
  end
end
