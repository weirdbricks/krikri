require "../minitest_helper"

# Real ansible-core 2.19.11 (community.crypto 3.1.1) registered-result key
# order for the crypto plugins - live-verified via `{{ r | to_json }}` dumps
# on localhost plays (changed / unchanged rerun / check mode where they
# differ). `failed: false` is backfilled by the executor after the plugin
# JSON, so the plugin-level pins omit it, exactly as real's wire shows it
# between the module keys and the trailing `warnings`.
describe "openssl_privatekey plugin result key order" do
  it "serializes a fresh RSA generation as type-size-fingerprint before filename" do
    dir = PluginSpecHelper.tmp_path("ko-pk1")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "type", "size", "fingerprint", "filename", "changed",
    ])
  end

  it "keeps the same order on an idempotent unchanged rerun" do
    dir = PluginSpecHelper.tmp_path("ko-pk2")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "type", "size", "fingerprint", "filename", "changed",
    ])
  end

  it "places curve between fingerprint and filename for ECC keys" do
    dir = PluginSpecHelper.tmp_path("ko-pk3")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "secp256r1", "size" => "256"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "type", "size", "fingerprint", "curve", "filename", "changed",
    ])
  end
end

describe "openssl_privatekey_info plugin result key order" do
  it "serializes an RSA key read with the info keys in real's order" do
    dir = PluginSpecHelper.tmp_path("ko-pki1")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
    result = PluginSpecHelper.run("openssl_privatekey_info", {"path" => path})

    result["can_load_key"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "can_load_key", "can_parse_key", "key_is_consistent", "public_key",
      "public_key_fingerprints", "type", "public_data", "changed",
    ])
  end

  it "places private_data after public_data with return_private_key_data" do
    dir = PluginSpecHelper.tmp_path("ko-pki2")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
    result = PluginSpecHelper.run("openssl_privatekey_info",
      {"path" => path, "return_private_key_data" => "true"})

    result["can_load_key"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "can_load_key", "can_parse_key", "key_is_consistent", "public_key",
      "public_key_fingerprints", "type", "public_data", "private_data", "changed",
    ])
  end
end

describe "openssl_publickey plugin result key order" do
  it "serializes a fresh derivation as privatekey-filename-format-changed-fingerprint" do
    dir = PluginSpecHelper.tmp_path("ko-pub1")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    result = PluginSpecHelper.run("openssl_publickey",
      {"path" => File.join(dir, "pub.pem"), "privatekey_path" => key})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "privatekey", "filename", "format", "changed", "fingerprint",
    ])
  end

  it "keeps the same order on an idempotent unchanged rerun" do
    dir = PluginSpecHelper.tmp_path("ko-pub2")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    PluginSpecHelper.run("openssl_publickey",
      {"path" => File.join(dir, "pub.pem"), "privatekey_path" => key})
    result = PluginSpecHelper.run("openssl_publickey",
      {"path" => File.join(dir, "pub.pem"), "privatekey_path" => key})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "privatekey", "filename", "format", "changed", "fingerprint",
    ])
  end
end

describe "openssl_publickey_info plugin result key order" do
  it "serializes a PEM public key read with the info keys in real's order" do
    dir = PluginSpecHelper.tmp_path("ko-pubi1")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    pub = File.join(dir, "pub.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    PluginSpecHelper.run("openssl_publickey", {"path" => pub, "privatekey_path" => key})
    result = PluginSpecHelper.run("openssl_publickey_info", {"path" => pub})

    result.as_h.keys.must_equal([
      "can_load_key", "can_parse_key", "key_is_consistent", "fingerprints",
      "type", "public_data", "changed",
    ])
  end
end

describe "openssl_dhparam plugin result key order" do
  it "serializes a fresh 512-bit generation as size-filename-changed" do
    dir = PluginSpecHelper.tmp_path("ko-dh1")
    FileUtils.mkdir_p(dir)
    result = PluginSpecHelper.run("openssl_dhparam",
      {"path" => File.join(dir, "dh.pem"), "size" => "512"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["size", "filename", "changed", "msg"])
  end

  it "keeps the same order on an idempotent unchanged rerun" do
    dir = PluginSpecHelper.tmp_path("ko-dh2")
    FileUtils.mkdir_p(dir)
    PluginSpecHelper.run("openssl_dhparam",
      {"path" => File.join(dir, "dh.pem"), "size" => "512"})
    result = PluginSpecHelper.run("openssl_dhparam",
      {"path" => File.join(dir, "dh.pem"), "size" => "512"})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["size", "filename", "changed", "msg"])
  end
end

# A PKCS#12 export needs a certificate alongside the key; make a
# throwaway self-signed one with the openssl CLI (same as the live
# verification play did).
private def self_signed_cert(dir : String, key : String) : String
  cert = File.join(dir, "cert.pem")
  status = Process.run("openssl", ["req", "-x509", "-new", "-key", key,
    "-subj", "/CN=test.example.com", "-days", "365", "-out", cert])
  status.success?.must_equal(true)
  cert
end

describe "openssl_pkcs12 plugin result key order" do
  it "serializes a fresh export as filename-privatekey_path-changed-mode" do
    dir = PluginSpecHelper.tmp_path("ko-p12-1")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    cert = self_signed_cert(dir, key)
    result = PluginSpecHelper.run("openssl_pkcs12", {
      "path"             => File.join(dir, "chain.p12"),
      "privatekey_path"  => key,
      "certificate_path" => cert,
      "friendly_name"    => "test",
      "action"           => "export",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "filename", "privatekey_path", "changed", "mode",
    ])
  end

  it "keeps the same order on an idempotent unchanged rerun" do
    dir = PluginSpecHelper.tmp_path("ko-p12-2")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    cert = self_signed_cert(dir, key)
    PluginSpecHelper.run("openssl_pkcs12", {
      "path"             => File.join(dir, "chain.p12"),
      "privatekey_path"  => key,
      "certificate_path" => cert,
      "friendly_name"    => "test",
      "action"           => "export",
    })
    result = PluginSpecHelper.run("openssl_pkcs12", {
      "path"             => File.join(dir, "chain.p12"),
      "privatekey_path"  => key,
      "certificate_path" => cert,
      "friendly_name"    => "test",
      "action"           => "export",
    })

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "filename", "privatekey_path", "changed",
    ])
  end
end

describe "x509_certificate plugin result key order" do
  it "serializes a fresh selfsigned generation with the cert details after csr" do
    dir = PluginSpecHelper.tmp_path("ko-x509-1")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    csr = File.join(dir, "req.csr")
    PluginSpecHelper.run("openssl_csr", {
      "path"            => csr,
      "privatekey_path" => key,
      "common_name"     => "test.example.com",
    })
    result = PluginSpecHelper.run("x509_certificate", {
      "path"            => File.join(dir, "cert.pem"),
      "privatekey_path" => key,
      "csr_path"        => csr,
      "provider"        => "selfsigned",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "privatekey", "csr", "notBefore", "notAfter", "serial_number",
      "changed", "filename",
    ])
  end

  it "keeps the same order on an idempotent unchanged rerun" do
    dir = PluginSpecHelper.tmp_path("ko-x509-2")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    csr = File.join(dir, "req.csr")
    PluginSpecHelper.run("openssl_csr", {
      "path"            => csr,
      "privatekey_path" => key,
      "common_name"     => "test.example.com",
    })
    params = {
      "path"            => File.join(dir, "cert.pem"),
      "privatekey_path" => key,
      "csr_path"        => csr,
      "provider"        => "selfsigned",
    }
    PluginSpecHelper.run("x509_certificate", params)
    result = PluginSpecHelper.run("x509_certificate", params)

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "privatekey", "csr", "notBefore", "notAfter", "serial_number",
      "changed", "filename",
    ])
  end

  it "serializes a state=absent removal changed-first" do
    dir = PluginSpecHelper.tmp_path("ko-x509-3")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    csr = File.join(dir, "req.csr")
    PluginSpecHelper.run("openssl_csr", {
      "path"            => csr,
      "privatekey_path" => key,
      "common_name"     => "test.example.com",
    })
    PluginSpecHelper.run("x509_certificate", {
      "path"            => File.join(dir, "cert.pem"),
      "privatekey_path" => key,
      "csr_path"        => csr,
      "provider"        => "selfsigned",
    })
    result = PluginSpecHelper.run("x509_certificate", {
      "path" => File.join(dir, "cert.pem"), "state" => "absent",
    })

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed", "filename"])
  end
end

describe "x509_certificate_info plugin result key order" do
  it "serializes a certificate read in real's info order" do
    dir = PluginSpecHelper.tmp_path("ko-x509i-1")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    csr = File.join(dir, "req.csr")
    PluginSpecHelper.run("openssl_csr", {
      "path"            => csr,
      "privatekey_path" => key,
      "common_name"     => "test.example.com",
    })
    PluginSpecHelper.run("x509_certificate", {
      "path"            => File.join(dir, "cert.pem"),
      "privatekey_path" => key,
      "csr_path"        => csr,
      "provider"        => "selfsigned",
    })
    result = PluginSpecHelper.run("x509_certificate_info",
      {"path" => File.join(dir, "cert.pem")})

    # The cert krikri's selfsigned provider issues from this CSR carries
    # subjectAltName (the CSR's CN-derived SAN) and no basicConstraints,
    # so those two appear in place of the basic_constraints pair the
    # live-verified dump had - same list, absent keys skipped.
    result.as_h.keys.must_equal([
      "signature_algorithm", "subject", "subject_ordered", "issuer",
      "issuer_ordered", "version", "subject_alt_name",
      "subject_alt_name_critical", "not_before", "not_after", "expired",
      "public_key", "public_key_type", "public_key_data",
      "public_key_fingerprints", "fingerprints", "subject_key_identifier",
      "serial_number", "changed",
    ])
  end
end

describe "openssh_keypair plugin result key order" do
  it "serializes a fresh rsa generation as size-type-filename-fingerprint-public_key-comment" do
    dir = PluginSpecHelper.tmp_path("ko-ssh-1")
    FileUtils.mkdir_p(dir)
    result = PluginSpecHelper.run("openssh_keypair",
      {"path" => File.join(dir, "id_test"), "type" => "rsa", "size" => "2048"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "size", "type", "filename", "fingerprint", "public_key", "comment", "changed", "msg",
    ])
  end

  it "keeps the same order on an idempotent unchanged rerun" do
    dir = PluginSpecHelper.tmp_path("ko-ssh-2")
    FileUtils.mkdir_p(dir)
    params = {"path" => File.join(dir, "id_test"), "type" => "rsa", "size" => "2048"}
    PluginSpecHelper.run("openssh_keypair", params)
    result = PluginSpecHelper.run("openssh_keypair", params)

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "size", "type", "filename", "fingerprint", "public_key", "comment", "changed", "msg",
    ])
  end
end

describe "openssl_csr plugin result key order" do
  it "serializes a generated CSR with extension keys in real's order" do
    dir = PluginSpecHelper.tmp_path("ko-csr1")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    result = PluginSpecHelper.run("openssl_csr", {
      "path"           => File.join(dir, "req.csr"),
      "privatekey_path" => key,
      "common_name"    => "test.example.com",
    })

    result.as_h.keys.must_equal([
      "privatekey", "subject", "subjectAltName", "keyUsage", "extendedKeyUsage",
      "basicConstraints", "ocspMustStaple", "name_constraints_permitted",
      "name_constraints_excluded", "filename", "changed",
    ])
  end
end
