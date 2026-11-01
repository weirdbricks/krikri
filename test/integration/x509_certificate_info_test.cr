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
    # openssl's default -x509 profile adds basicConstraints CA:TRUE; keyUsage,
    # extendedKeyUsage and SAN are not requested, so they come out as None.
    result["basic_constraints"].as_a.must_equal(["CA:TRUE"])
    # The extension keys are always present even when the certificate
    # carries none of them - None value, False critical flag.
    result["key_usage"].raw.must_be_nil
    result["key_usage_critical"].as_bool.must_equal(false)
    result["extended_key_usage"].raw.must_be_nil
    result["extended_key_usage_critical"].as_bool.must_equal(false)
    result["subject_alt_name"].raw.must_be_nil
    result["subject_alt_name_critical"].as_bool.must_equal(false)
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
    # The Ansible module returns key_usage as a sorted list of the OpenSSL
    # long names; "Key Encipherment" sorts before "Digital Signature".
    result["key_usage"].as_a.map(&.as_s).must_equal(["Digital Signature", "Key Encipherment"])
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

  # Live-verified against ansible-core 2.19.11 (community.crypto 3.1.1):
  # the registered result's key list ends `valid_at`, `failed`, `changed`
  # - real registers failed=false inside the module's own key order,
  # before changed. A plugin success result that doesn't put failed on
  # the wire gets it backfilled by the executor AFTER changed instead.
  it "registers valid_at, failed, changed as the result's final keys" do
    path = cert_path("key-order.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("key-order.key")} -out #{path} -days 30 -nodes -subj "/CN=www.example.com" 2>/dev/null`

    playbook = File.tempname("x509-key-order", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Read certificate
            community.crypto.x509_certificate_info:
              path: #{path}
            register: info
          - name: Show top-level result key order
            debug:
              msg: "{{ info.keys() | list }}"
      YAML

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
    output = captured.to_s
    status.success?.must_equal(true, "playbook failed: #{output}")
    tail = /"valid_at",\s*"failed",\s*"changed"/
    output.matches?(tail).must_equal(true, "expected valid_at, failed, changed tail, got: #{output}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

# The pacifica.ansible_certinfra gaps (#366, #367, #369 and the extensions_by_oid hole),
# each value checked against community.crypto 3.1.1 on a leaf with the same extension shape.
describe "x509_certificate_info: AIA, TLS feature, extensions_by_oid, EC curves" do
  private def leaf_with_aia : String
    ca = cert_path("aia-ca.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("aia-ca.key")} -out #{ca} -days 30 -nodes -subj "/CN=AIA-CA" 2>/dev/null`
    ext = cert_path("aia.cnf")
    File.write(ext, <<-CNF)
      [leaf]
      keyUsage = critical, digitalSignature
      authorityInfoAccess = OCSP;URI:http://ocsp.example.test, caIssuers;URI:http://ca.example.test/ca.crt
      1.3.6.1.5.5.7.1.24 = DER:30:03:02:01:05
      CNF
    `openssl req -newkey rsa:2048 -nodes -keyout #{cert_path("aia.key")} -out #{cert_path("aia.csr")} -subj "/CN=aia.test" 2>/dev/null`
    leaf = cert_path("aia.pem")
    `openssl x509 -req -in #{cert_path("aia.csr")} -CA #{ca} -CAkey #{cert_path("aia-ca.key")} -CAcreateserial -out #{leaf} -days 10 -extfile #{ext} -extensions leaf 2>/dev/null`
    leaf
  end

  it "reads ocsp_uri, issuer_uri and OCSP must-staple from extensions without the X509v3 prefix" do
    result = PluginSpecHelper.run("x509_certificate_info", {"path" => leaf_with_aia})
    result["ocsp_uri"].as_s.must_equal("http://ocsp.example.test")
    result["issuer_uri"].as_s.must_equal("http://ca.example.test/ca.crt")
    result["ocsp_must_staple"].as_bool.must_equal(true)
    result["ocsp_must_staple_critical"].as_bool.must_equal(false)
    # the extension before them keeps its own body (it used to swallow theirs)
    result["key_usage"].as_a.map(&.as_s).must_equal(["Digital Signature"])
  end

  it "reports every extension by OID with its critical flag and base64 DER value" do
    by_oid = PluginSpecHelper.run("x509_certificate_info", {"path" => leaf_with_aia})["extensions_by_oid"].as_h
    # in the certificate's own order; openssl 3's `x509 -req` appends SKI and AKI itself
    by_oid.keys.must_equal(["2.5.29.15", "1.3.6.1.5.5.7.1.1", "1.3.6.1.5.5.7.1.24", "2.5.29.14", "2.5.29.35"])
    by_oid["2.5.29.15"].as_h["critical"].as_bool.must_equal(true)
    by_oid["2.5.29.15"].as_h["value"].as_s.must_equal("AwIHgA==")
    by_oid["1.3.6.1.5.5.7.1.24"].as_h.must_equal({"critical" => JSON::Any.new(false), "value" => JSON::Any.new("MAMCAQU=")})
  end

  it "keeps the must-staple and AIA keys, as None, on a certificate without them" do
    path = cert_path("plain.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("plain.key")} -out #{path} -days 30 -nodes -subj "/CN=plain" 2>/dev/null`
    result = PluginSpecHelper.run("x509_certificate_info", {"path" => path})
    {"ocsp_must_staple", "ocsp_uri", "issuer_uri"}.each { |key| result[key].raw.must_be_nil }
    result["ocsp_must_staple_critical"].as_bool.must_equal(false)
  end

  it "names an X9.62 curve the way cryptography does, in the module's key order" do
    path = cert_path("ec.pem")
    `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout #{cert_path("ec.key")} -out #{path} -days 30 -nodes -subj "/CN=ec" 2>/dev/null`
    data = PluginSpecHelper.run("x509_certificate_info", {"path" => path})["public_key_data"].as_h
    data["curve"].as_s.must_equal("secp256r1")
    data.keys.must_equal(["curve", "x", "y", "exponent_size"])
  end

  it "carries invocation.module_args on loop-registered items (#367)" do
    path = cert_path("loop.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("loop.key")} -out #{path} -days 30 -nodes -subj "/CN=loop" 2>/dev/null`
    playbook = File.tempname("x509-invocation", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.crypto.x509_certificate_info:
              path: "{{ item }}"
            loop: ["#{path}"]
            register: info
          - debug:
              msg: "{{ info.results[0].invocation | to_json }}"
      YAML
    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
    output = captured.to_s
    status.success?.must_equal(true, output)
    output.must_include(%(\\"module_args\\": {\\"path\\": \\"#{path}\\", \\"name_encoding\\": \\"ignore\\", \\"select_crypto_backend\\": \\"auto\\", \\"content\\": null, \\"valid_at\\": null}))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

# Integers wider than Int64 (issue #364): the module returns Python ints
# for public_key_data.modulus and (almost always) serial_number; krikri
# used to quote them as decimal strings. The wire carries bare digits and
# the engine carries the BIGINT_SENTINEL_PREFIX-marked string, so every
# renderer prints the value the way Ansible's int does - unquoted.
describe "x509_certificate_info: wide integers" do
  it "carries modulus and serial_number as marked wide integers" do
    path = cert_path("wide.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("wide.key")} -out #{path} -days 30 -nodes -subj "/CN=wide" 2>/dev/null`
    result = PluginSpecHelper.run("x509_certificate_info", {"path" => path})

    modulus = Krikri.bigint_digits(result["public_key_data"].as_h["modulus"]).not_nil!
    (modulus.size >= 600).must_equal(true)
    serial = Krikri.bigint_digits(result["serial_number"]).not_nil!
    (serial.size >= 10).must_equal(true)
    # Small values stay plain Int64s.
    result["public_key_data"].as_h["exponent"].as_i.must_equal(65537)
    result["public_key_data"].as_h["size"].as_i.must_equal(2048)
  end

  it "renders a registered modulus unquoted through to_json, type_debug, debug var and interpolation" do
    path = cert_path("render.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("render.key")} -out #{path} -days 30 -nodes -subj "/CN=render" 2>/dev/null`
    playbook = File.tempname("x509-wide", ".yml")
    written = File.join(PluginSpecHelper.tmp_path("wide-dump"), "dump.json")
    written_nice = File.join(PluginSpecHelper.tmp_path("wide-dump"), "dump-nice.json")
    FileUtils.mkdir_p(File.dirname(written))
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.crypto.x509_certificate_info:
              path: "#{path}"
            register: info
          - debug:
              var: info.public_key_data.modulus
          - debug:
              msg: "{{ info.public_key_data.modulus }}"
          - debug:
              msg: "{{ info.public_key_data.modulus | type_debug }}"
          - debug:
              msg: "{{ info.public_key_data.modulus > 0 }}"
          - copy:
              content: "{{ info | to_json }}\n"
              dest: "#{written}"
          - copy:
              content: "{{ info | to_nice_json }}\n"
              dest: "#{written_nice}"
      YAML
    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
    output = captured.to_s
    status.success?.must_equal(true, output)

    # The marker must never leak into ANY rendered output.
    output.includes?("\u{E000}").must_equal(false, "sentinel marker leaked into display output:\n#{output}")

    rerun = PluginSpecHelper.run("x509_certificate_info", {"path" => path})
    modulus_digits = Krikri.bigint_digits(rerun["public_key_data"].as_h["modulus"]).not_nil!
    serial_digits = Krikri.bigint_digits(rerun["serial_number"]).not_nil!
    # debug: var= prints Python's repr - unquoted digits.
    output.must_include(%("info.public_key_data.modulus": #{modulus_digits}))
    # msg interpolation stringifies the int - bare digits, no quotes.
    output.must_include(%("msg": #{modulus_digits}))
    # type_debug says int.
    output.must_include(%("msg": "int"))
    # the comparison ran against the number, not a string (a str-vs-int
    # ordering fails the task under ansible's semantics)
    output.must_include(%("msg": true))

    dumped = File.read(written)
    dumped.includes?("\u{E000}").must_equal(false, "sentinel marker leaked into to_json output")
    dumped.must_include(%("modulus": #{modulus_digits}))
    dumped.must_include(%("serial_number": #{serial_digits}))

    dumped_nice = File.read(written_nice)
    dumped_nice.includes?("\u{E000}").must_equal(false, "sentinel marker leaked into to_nice_json output")
    dumped_nice.must_include(%("modulus": #{modulus_digits}))
    dumped_nice.must_include(%("serial_number": #{serial_digits}))
  end

  # Ordering comparisons against a marked wide integer, on BOTH evaluators
  # (the bare `when:` conditional path AND `{{ }}` templating), both
  # operand orientations, and the negated value. Live-verified against
  # ansible-core 2.19 with the same play: every run-here task runs there
  # and every skip-here task skips there.
  it "compares a wide integer in when: and {{ }} on both operand sides" do
    path = cert_path("compare.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("compare.key")} -out #{path} -days 30 -nodes -subj "/CN=compare" 2>/dev/null`
    playbook = File.tempname("x509-wide-cmp", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.crypto.x509_certificate_info:
              path: "#{path}"
            register: info
          - set_fact:
              m: "{{ info.public_key_data.modulus }}"
              neg: "{{ -info.public_key_data.modulus }}"
          - {debug: {msg: "RUN when 0 < m"}, when: "0 < m"}
          - {debug: {msg: "RUN when m > 0"}, when: "m > 0"}
          - {debug: {msg: "RUN when 5 < m"}, when: "5 < m"}
          - {debug: {msg: "RUN when m >= 5"}, when: "m >= 5"}
          - {debug: {msg: "RUN when m > 1.5"}, when: "m > 1.5"}
          - {debug: {msg: "RUN when 1.5 < m"}, when: "1.5 < m"}
          - {debug: {msg: "RUN when neg < 0"}, when: "neg < 0"}
          - {debug: {msg: "RUN when 0 > neg"}, when: "0 > neg"}
          - {debug: {msg: "RUN when neg < m"}, when: "neg < m"}
          - {debug: {msg: "RUN when m > neg"}, when: "m > neg"}
          - {debug: {msg: "RUN when modulus > 65537"}, when: "info.public_key_data.modulus > 65537"}
          - {debug: {msg: "RUN when 65537 < modulus"}, when: "65537 < info.public_key_data.modulus"}
          - {debug: {msg: "RUN when m == modulus"}, when: "m == info.public_key_data.modulus"}
          - {debug: {msg: "SKIP when 5 > m"}, when: "5 > m"}
          - {debug: {msg: "SKIP when m < 5"}, when: "m < 5"}
          - {debug: {msg: "SKIP when m < 0"}, when: "m < 0"}
          - {debug: {msg: "SKIP when 1.5 > m"}, when: "1.5 > m"}
          - {debug: {msg: "SKIP when neg > 0"}, when: "neg > 0"}
          - {debug: {msg: "SKIP when m > modulus"}, when: "m > info.public_key_data.modulus"}
          - debug:
              msg: "RUN tpl 0 < m => {{ 0 < m }}"
          - debug:
              msg: "RUN tpl 5 > m => {{ 5 > m }}"
          - debug:
              msg: "RUN tpl m < 5 => {{ m < 5 }}"
          - debug:
              msg: "RUN tpl m >= 1.5 => {{ m >= 1.5 }}"
          - debug:
              msg: "RUN tpl 1.5 >= m => {{ 1.5 >= m }}"
          - debug:
              msg: "RUN tpl -m < 0 => {{ -m < 0 }}"
          - debug:
              msg: "RUN tpl spaces => {{ -m < 0 }} <= kept"
          - debug:
              msg: "RUN tpl neg {{ -info.public_key_data.modulus > 0 }}"
      YAML

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
    output = captured.to_s
    status.success?.must_equal(true, "playbook failed: #{output}")

    # The marker must never leak into any rendered output.
    output.includes?("\u{E000}").must_equal(false, "sentinel marker leaked into comparison output:\n#{output}")

    ["0 < m", "m > 0", "5 < m", "m >= 5", "m > 1.5", "1.5 < m",
     "neg < 0", "0 > neg", "neg < m", "m > neg",
     "modulus > 65537", "65537 < modulus", "m == modulus"].each do |clause|
      output.must_include(%("msg": "RUN when #{clause}"))
    end
    ["5 > m", "m < 5", "m < 0", "1.5 > m", "neg > 0", "m > modulus"].each do |clause|
      output.wont_include("SKIP when #{clause}\"")
    end
    output.must_include(%("msg": "RUN tpl 0 < m => True"))
    output.must_include(%("msg": "RUN tpl 5 > m => False"))
    output.must_include(%("msg": "RUN tpl m < 5 => False"))
    output.must_include(%("msg": "RUN tpl m >= 1.5 => True"))
    output.must_include(%("msg": "RUN tpl 1.5 >= m => False"))
    # The unary minus applies to the wide value AND the span's surrounding
    # literal text keeps its whitespace (the `{{ -... }}` body used to be
    # misread as a `{{-` trim marker, eating the minus and the space).
    output.must_include(%("msg": "RUN tpl -m < 0 => True"))
    output.must_include(%("msg": "RUN tpl spaces => True <= kept"))
    output.must_include(%("msg": "RUN tpl neg False"))
  end

  # Python's float(int) raises OverflowError("int too large to convert to
  # float") on a modulus-scale integer and Ansible fails the task with it;
  # silently coercing to 0.0 (the old behavior) produced a WRONG value.
  it "fails a wide int | float like Ansible's OverflowError" do
    path = cert_path("floatfail.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("floatfail.key")} -out #{path} -days 30 -nodes -subj "/CN=floatfail" 2>/dev/null`
    playbook = File.tempname("x509-wide-float", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.crypto.x509_certificate_info:
              path: "#{path}"
            register: info
          - debug:
              msg: "{{ info.public_key_data.modulus | float > 1e300 }}"
      YAML

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
    output = captured.to_s
    status.success?.must_equal(false, "the overflow must fail the task: #{output}")
    output.must_include("int too large to convert to float")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

# Issue #701 (pacifica.ansible_certinfra, round 29891662): the module
# MUTATES module.params["valid_at"] in place while resolving each probe,
# so the echoed invocation.module_args.valid_at holds the RESOLVED
# datetimes, not the raw timespecs (live-verified vs ansible-core
# 2.19.11 / community.crypto 3.1.1; the +00:00 suffix rides the target's
# cryptography >= 42, hence the optional group in the regexes). The
# invocation echo only survives register inside a LOOP's per-item
# results, so these run through the role-shaped loop the way the real
# role reads them.
describe "x509_certificate_info: valid_at invocation echo" do
  private def run_echo_playbook(tasks : String) : String
    path = cert_path("echo.pem")
    `openssl req -x509 -newkey rsa:2048 -keyout #{cert_path("echo.key")} -out #{path} -days 30 -nodes -subj "/CN=echo.example.com" 2>/dev/null`
    playbook = File.tempname("x509-valid-at-echo", ".yml")
    File.write(playbook, <<-YAML + "\n" + tasks.gsub("CERTPATH", path))
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
    YAML
    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
    output = captured.to_s
    status.success?.must_equal(true, "playbook failed: #{output}")
    output
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "echoes a relative timespec resolved to the absolute datetime it was evaluated against" do
    output = run_echo_playbook(<<-TASKS)
        - community.crypto.x509_certificate_info:
            path: CERTPATH
            valid_at: {"one_week": "+1w"}
          loop: [0]
          register: result
        - debug:
            msg: "{{ result.results[0].invocation.module_args.valid_at | to_json }}"
    TASKS

    # %Y-%m-%dT%H:%M:%S + microseconds when nonzero (Python's isoformat),
    # +00:00 only when the target's cryptography is timezone-aware.
    output.matches?(/\\"one_week\\": \\"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{6})?(\+00:00)?\\"/).must_equal(true,
      "expected the resolved datetime echo, got: #{output}")
  end

  it "echoes an absolute timespec normalized (offset spelling added, microseconds omitted at 0)" do
    output = run_echo_playbook(<<-TASKS)
        - community.crypto.x509_certificate_info:
            path: CERTPATH
            valid_at: {"abs": "20370101000000Z"}
          loop: [0]
          register: result
        - debug:
            msg: "{{ result.results[0].invocation.module_args.valid_at | to_json }}"
    TASKS

    # The raw "20370101000000Z" must not survive into the echo, and the
    # zero-microsecond datetime must NOT carry a fraction (Python's
    # isoformat omits .000000).
    output.wont_include("20370101000000Z")
    output.matches?(/\\"abs\\": \\"2037-01-01T00:00:00(\+00:00)?\\"/).must_equal(true,
      "expected the normalized zero-microsecond echo, got: #{output}")
  end

  it "echoes every key of a multi-probe valid_at resolved, booleans unchanged" do
    output = run_echo_playbook(<<-TASKS)
        - community.crypto.x509_certificate_info:
            path: CERTPATH
            valid_at: {"one_week": "+1w", "ago": "-2d3h", "abs": "20370101000000Z"}
          loop: [0]
          register: result
        - debug:
            msg: "{{ result.results[0].invocation.module_args.valid_at | to_json }} BOOLS {{ result.results[0].valid_at | to_json }}"
    TASKS

    output.matches?(/\\"one_week\\": \\"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{6})?(\+00:00)?\\"/).must_equal(true, output)
    output.matches?(/\\"ago\\": \\"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{6})?(\+00:00)?\\"/).must_equal(true, output)
    output.matches?(/\\"abs\\": \\"2037-01-01T00:00:00(\+00:00)?\\"/).must_equal(true, output)
    # The probe booleans ride beside the echo, unchanged: +1w inside the
    # 30-day validity, -2d3h before not_before (the cert was just
    # minted), 2037 far past not_after.
    output.matches?(/BOOLS \{\\"one_week\\": true, \\"ago\\": false, \\"abs\\": false\}/).must_equal(true, output)
  end

  it "keeps a type-error failure's echo with earlier keys resolved and the failing key raw" do
    output = run_echo_playbook(<<-TASKS)
        - community.crypto.x509_certificate_info:
            path: CERTPATH
            valid_at: {"ok": "+1w", "int": 5}
          loop: [0]
          register: result
          ignore_errors: true
        - debug:
            msg: "{{ result.results[0] | to_json }}"
    TASKS

    output.must_include(%(The value for valid_at.int must be of type string (got <class 'int'>)))
    # fail_json's echo: the resolved key stays resolved, the failing one raw.
    output.matches?(/\\"ok\\": \\"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{6})?(\+00:00)?\\", \\"int\\": 5/).must_equal(true, output)
  end

  it "puts invocation after msg in a type-error failure's key order (#703)" do
    output = run_echo_playbook(<<-TASKS)
        - community.crypto.x509_certificate_info:
            path: CERTPATH
            valid_at: {"ok": "+1w", "int": 5}
          loop: [0]
          register: result
          ignore_errors: true
        - debug:
            msg: "{{ result.results[0].keys() | list | to_json }}"
    TASKS

    output.must_include(%([\\"failed\\", \\"msg\\", \\"invocation\\", \\"changed\\", \\"exception\\", \\"item\\", \\"ansible_loop_var\\"]))
  end

  it "fails an invalid timespec with the uncaught-exception shape and no invocation echo" do
    output = run_echo_playbook(<<-TASKS)
        - community.crypto.x509_certificate_info:
            path: CERTPATH
            valid_at: {"bad": "not-a-time"}
          loop: [0]
          register: result
          ignore_errors: true
        - debug:
            msg: "{{ result.results[0] | to_json }}"
    TASKS

    # The valid_at loop sits OUTSIDE the module's try block: the raise is
    # uncaught, the controller wraps it ("Task failed: Module failed: "),
    # and the module output carries no invocation at all.
    output.must_include(%(Task failed: Module failed: The time spec "not-a-time" for valid_at.bad is invalid))
    output.wont_include("invocation")
  end

  it "uses the relative timespec wording for a lone + spec" do
    output = run_echo_playbook(<<-TASKS)
        - community.crypto.x509_certificate_info:
            path: CERTPATH
            valid_at: {"plus": "+"}
          loop: [0]
          register: result
          ignore_errors: true
        - debug:
            msg: "{{ result.results[0].msg }}"
    TASKS

    output.must_include(%(Task failed: Module failed: The timespec "+" for valid_at.plus is invalid))
  end
end
