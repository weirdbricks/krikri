require "../minitest_helper"
require "file_utils"

# community.crypto.x509_certificate_info - read-only certificate facts.
# Field shapes verified against the Ansible module (community.crypto 3.1.1,
# ansible-core 2.19.4) rather than the docs: same vocabulary (OpenSSL LN
# names through cryptography's OID table), same sorted list extensions,
# same ASN.1 TIME validity spelling, same colon-hex fingerprints.
# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def cert_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

describe "x509_certificate_info plugin" do
  it "reports subject, issuer, validity, serial and version for a self-signed cert" do
    path = cert_path("basic.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("basic.key")} -out #{path} -days 30 -nodes -subj "/CN=www.example.com/O=Test Org" 2>/dev/null`

    result = PluginSpecHelper.run("x509_certificate_info", {"path" => path})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["version"].as_i.must_equal(3)
    result["subject"].as_h["commonName"].as_s.must_equal("www.example.com")
    result["subject"].as_h["organizationName"].as_s.must_equal("Test Org")
    result["subject_ordered"].as_a[0].as_a[0].as_s.must_equal("commonName")
    result["issuer"].as_h["commonName"].as_s.must_equal("www.example.com")
    result["signature_algorithm"].as_s.must_equal("sha256WithRSAEncryption")
    result["expired"].as_bool.must_equal(false)
    # ASN.1 TIME spelling, both ends.
    result["not_before"].as_s.must_match(/^\d{14}Z$/)
    result["not_after"].as_s.must_match(/^\d{14}Z$/)
    result["public_key_type"].as_s.must_equal("RSA")
    result["public_key_data"].as_h["exponent"].as_i.must_equal(65537)
    result["public_key_data"].as_h["size"].as_i.must_equal(2048)
  end

  it "parses the extension set: basic constraints, key usage, extended key usage, SAN" do
    path = cert_path("exts.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("exts.key")} -out #{path} -days 30 -nodes \
      -subj "/CN=exts.example.com" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=serverAuth" \
      -addext "subjectAltName=DNS:www.example.com,IP:1.2.3.4" 2>/dev/null`

    result = PluginSpecHelper.run("x509_certificate_info", {"path" => path})

    result["basic_constraints"].as_a.must_equal(["CA:TRUE"])
    result["basic_constraints_critical"].as_bool.must_equal(true)
    # The Ansible module sorts the key usage entries and joins them into one
    # string; "Key Encipherment" sorts before "Digital Signature".
    result["key_usage"].as_s.must_equal("Digital Signature, Key Encipherment")
    result["key_usage_critical"].as_bool.must_equal(false)
    result["extended_key_usage"].as_a.must_equal(["TLS Web Server Authentication"])
    # The Ansible module renders SAN IP entries as "IP:...", not openssl's
    # "IP Address:..." spelling.
    result["subject_alt_name"].as_a.map(&.as_s).must_equal(["DNS:www.example.com", "IP:1.2.3.4"])
  end

  it "reports expired for a cert whose notAfter is in the past" do
    path = cert_path("expired.pem")
    # openssl req rejects non-positive -days, so backdate with -not_after
    # (OpenSSL 3) when available; a missing file means the local openssl
    # can't backdate and this environment can't test the flag.
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("expired.key")} -out #{path} -nodes -subj "/CN=old.example.com" -not_after 20200101000000Z 2>/dev/null`
    skip "openssl lacks -not_after; cannot backdate a certificate" unless File.exists?(path)

    result = PluginSpecHelper.run("x509_certificate_info", {"path" => path})

    result["expired"].as_bool.must_equal(true)
  end

  it "fails for a missing path, and for path+content given together" do
    result = PluginSpecHelper.run("x509_certificate_info", {"path" => cert_path("nope.pem")})
    result["failed"].as_bool.must_equal(true)

    result = PluginSpecHelper.run("x509_certificate_info",
      {"path" => "/dev/null", "content" => "-----BEGIN CERTIFICATE-----"})
    result["failed"].as_bool.must_equal(true)
  end

  # community.crypto's x509_certificate_info.py: result["valid_at"] is
  # ALWAYS present ({} when the option is absent), each probe a boolean
  # from not_before <= point <= not_after with the probe resolved via
  # _time.py get_relative_time_option. Round 5420006
  # (pacifica.ansible_certinfra): the role's one-week-validity probe
  # registers cert_valid_result and the NEXT task reads
  # result.valid_at.one_week - an absent dict fails that conditional
  # with "object of type 'dict' has no attribute 'valid_at'".
  it "answers valid_at probes: relative future true, past notAfter false, absolute before notBefore false" do
    path = cert_path("validat.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("validat.key")} -out #{path} -days 30 -nodes -subj "/CN=validat.example.com" 2>/dev/null`

    result = PluginSpecHelper.run("x509_certificate_info", {
      "path"     => path,
      "valid_at" => %({"one_week": "+1w", "past_not_after": "+40d", "before_not_before": "20200102030405Z"}),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    valid_at = result["valid_at"].as_h
    valid_at["one_week"].as_bool.must_equal(true)
    valid_at["past_not_after"].as_bool.must_equal(false)
    valid_at["before_not_before"].as_bool.must_equal(false)
    # One boolean per probe, keyed by the caller's probe names.
    valid_at.size.must_equal(3)
  end

  it "carries an empty valid_at dict when the option is absent" do
    path = cert_path("novalidat.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("novalidat.key")} -out #{path} -days 30 -nodes -subj "/CN=novalidat.example.com" 2>/dev/null`

    result = PluginSpecHelper.run("x509_certificate_info", {"path" => path})

    result["valid_at"].as_h.must_equal({} of String => JSON::Any)
  end

  # The role's conditional shape end-to-end: the registered result feeds
  # both a direct `not result.valid_at.one_week` when: (the role's
  # "Remove the cert if it's not valid in one week") and the
  # with_nested `item.0.valid_at.one_week` reading its next task does
  # over the registered result.
  it "feeds the role's valid_at conditionals end-to-end: direct when and with_nested item.0" do
    path = cert_path("conditional.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("conditional.key")} -out #{path} -days 30 -nodes -subj "/CN=conditional.example.com" 2>/dev/null`

    playbook = File.tempname("x509-valid-at", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Test whether that certificate is valid in one week
            community.crypto.x509_certificate_info:
              path: #{path}
              valid_at:
                one_week: "+1w"
            register: result
          - name: Remove the cert if it's not valid in one week
            file:
              path: #{path}
              state: absent
            when:
              - not result.valid_at.one_week
          - name: Role-shaped nested conditional over the registered result
            debug:
              msg: "valid={{ item.0.valid_at.one_week }}"
            with_nested:
              - "{{ [result] }}"
              - "{{ [1] }}"
            register: nested
          - name: Everything must agree the cert is valid
            assert:
              that:
                - result.valid_at.one_week
                - nested.results[0].msg == "valid=True"
    YAML

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
    output = captured.to_s
    status.success?.must_equal(true, "playbook failed: #{output}")
    output.must_include("valid=True")
    output.wont_include("has no attribute 'valid_at'")
    # The remove task's when: was false, so the cert survived.
    File.exists?(path).must_equal(true)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
