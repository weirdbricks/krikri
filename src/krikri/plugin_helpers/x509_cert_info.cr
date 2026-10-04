require "json"
require "openssl/digest"
require "base64"

module Krikri
  # Shared X.509 certificate parsing for the community.crypto info
  # modules (`x509_certificate_info`, `get_certificate`). Both plugins
  # need the same field set - subject/issuer dicts, validity, extensions,
  # fingerprints, public key data - so it lives here once, driven by the
  # `openssl` CLI (the same backend choice every other crypto plugin in
  # this tree makes; there is no Python cryptography library to lean on
  # on the target host).
  #
  # Field vocabularies were matched against the real module
  # (community.crypto 3.1.1, ansible-core 2.19.4), whose own output comes
  # from Python's `cryptography` library mapped through OpenSSL's
  # objects.txt long names - which is exactly the vocabulary `openssl
  # x509 -text` itself prints, so most fields read straight off that
  # output. The module sorts every list-valued extension it returns
  # (key usage, extended key usage, basic constraints), which openssl
  # does not do, so parsed entries are sorted here.
  #
  # Deliberately not implemented: `extensions_by_oid` for CERTIFICATES
  # (the DER-encoded value of every extension). For CSR parsing it IS
  # implemented - see parse_extensions_by_oid - so openssl_csr_info's
  # result carries the full real key set.
  module X509CertInfo
    # hashlib.algorithms_guaranteed - ALL of it, including the two SHAKE
    # XOFs: the real module emits them too (its bare hexdigest() call
    # raises TypeError on the XOFs and falls back to hexdigest(32), i.e.
    # 32 BYTES for both shake_128 and shake_256). Crystal's
    # OpenSSL::Digest cannot finalize an XOF (EVP_DigestFinal_ex has no
    # XOF length knob - live-verified: it errors on both), so the SHAKE
    # pair goes through the `openssl dgst -shakeN -xoflen 32` CLI
    # instead (OpenSSL 3.0+, jammy's 3.0.2 included). On an older
    # openssl the CLI call fails and the two entries are omitted - the
    # same graceful degradation the hash loop's rescue already applies.
    # Everything else is emitted under the real module's Python
    # algorithm names.
    FINGERPRINT_ALGORITHMS = {
      "md5"      => "md5",
      "sha1"     => "sha1",
      "sha224"   => "sha224",
      "sha256"   => "sha256",
      "sha384"   => "sha384",
      "sha512"   => "sha512",
      "sha3_224" => "sha3-224",
      "sha3_256" => "sha3-256",
      "sha3_384" => "sha3-384",
      "sha3_512" => "sha3-512",
      "blake2b"  => "blake2b512",
      "blake2s"  => "blake2s256",
    }

    # The two SHAKE XOFs under their real-module (hashlib) names. The
    # digest length is fixed at 32 bytes - the real module's
    # `hexdigest(32)` fallback, not the XOF's nominal block size.
    SHAKE_ALGORITHMS = {
      "shake_128" => "shake128",
      "shake_256" => "shake256",
    }

    # A value that fits Int64 stays a JSON number (matching the real
    # module's Python ints); anything wider - RSA moduli, ECC
    # coordinates, big serial numbers - goes out as its decimal string,
    # because this engine's result world is JSON::Any (Int64 at widest)
    # and truncating digits would be worse than a string.
    def self.json_int(decimal : String) : JSON::Any
      JSON::Any.new(decimal.to_i64? || decimal)
    rescue
      JSON::Any.new(decimal)
    end

    # Hex string -> decimal string, for values far wider than Int64 (an
    # RSA modulus is 2048+ bits). Base-10 school multiplication over the
    # hex nibbles - no BigInt shard in this tree.
    def self.big_hex_to_decimal(hex : String) : String
      # A leading 0x00 (or zero nibble) is openssl's sign byte, not part
      # of the magnitude.
      hex = hex.lstrip('0')
      return "0" if hex.empty?
      digits = [] of UInt8
      hex.each_char do |char|
        nibble = char.to_i?(16)
        return hex unless nibble
        carry = nibble
        i = digits.size
        while i > 0
          i -= 1
          value = digits[i].to_i32 * 16 + carry
          digits[i] = (value % 10).to_u8
          carry = value // 10
        end
        while carry > 0
          digits.unshift((carry % 10).to_u8)
          carry //= 10
        end
      end
      digits.empty? ? "0" : digits.join
    end

    def self.fingerprints(data : Bytes) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      FINGERPRINT_ALGORITHMS.each do |py_name, ossl_name|
        hex = OpenSSL::Digest.new(ossl_name).update(data).final.hexstring
        result[py_name] = JSON::Any.new(hex.chars.each_slice(2).map(&.join).join(":"))
      end
      SHAKE_ALGORITHMS.each do |py_name, ossl_name|
        hex = shake_hexstring(ossl_name, data)
        result[py_name] = JSON::Any.new(hex.chars.each_slice(2).map(&.join).join(":")) if hex
      end
      result
    rescue
      {} of String => JSON::Any
    end

    # `openssl dgst -shakeN -xoflen 32 -hex` over the raw bytes: the
    # output line's last "="-separated field is the hex digest. nil when
    # the local openssl predates the XOF flags (pre-3.0).
    private def self.shake_hexstring(ossl_name : String, data : Bytes) : String?
      stdout_io = IO::Memory.new
      status = Process.run("openssl", ["dgst", "-#{ossl_name}", "-xoflen", "32", "-hex"],
        input: IO::Memory.new(data), output: stdout_io, error: IO::Memory.new)
      return nil unless status.success?
      hex = stdout_io.to_s.split("=").last?.to_s.strip
      hex.empty? ? nil : hex
    end

    def self.fingerprints_any(data : Bytes) : JSON::Any
      JSON::Any.new(fingerprints(data).to_h { |k, v| {k, v} })
    end

    # The main entry point: *cert_pem* is the PEM text of one
    # certificate. Returns the module's result fields as a hash, or nil
    # if openssl cannot parse it at all.
    def self.parse(cert_pem : String, now : Time = Time.utc) : Hash(String, JSON::Any)?
      pem_file = File.tempname("x509info")
      File.write(pem_file, cert_pem)
      begin
        text = run_openssl(["x509", "-in", pem_file, "-noout", "-text"])
        return nil unless text

        names = run_openssl(["x509", "-in", pem_file, "-noout", "-subject", "-issuer", "-nameopt", "lname"])
        dates = run_openssl(["x509", "-in", pem_file, "-noout", "-startdate", "-enddate"])
        serial = run_openssl(["x509", "-in", pem_file, "-noout", "-serial"])
        pubkey_pem = run_openssl(["x509", "-in", pem_file, "-noout", "-pubkey"])
        der = der_bytes(["x509", "-in", pem_file, "-outform", "DER"])
        spki_der = nil
        if pubkey_pem
          pubkey_file = File.tempname("x509pub")
          File.write(pubkey_file, pubkey_pem)
          begin
            spki_der = der_bytes(["pkey", "-pubin", "-in", pubkey_file, "-outform", "DER"])
          ensure
            File.delete(pubkey_file) if File.exists?(pubkey_file)
          end
        end

        result = {} of String => JSON::Any
        parse_version_and_signature(text, result)
        parse_names(names, result)
        parse_validity(dates, now, result)
        parse_serial(serial, result)
        parse_extensions(text, result)
        parse_public_key(pubkey_pem, spki_der, result)

        result["fingerprints"] = fingerprints_any(der) if der
        result["public_key_fingerprints"] = fingerprints_any(spki_der) if spki_der
        result
      ensure
        File.delete(pem_file) if File.exists?(pem_file)
      end
    end

    # The openssl_csr_info half of the family: parses a PKCS#10
    # certificate request and returns the fields the real module
    # (community.crypto 3.1.1, csr_info.py's get_info) returns that this
    # openssl-CLI backend can produce: subject, subject_ordered,
    # key_usage/extended_key_usage/basic_constraints/ocsp_must_staple/
    # subject_alt_name (each with its _critical flag, absent exactly
    # when the extension is absent - matching the real backend's None),
    # public_key, public_key_type, public_key_data,
    # public_key_fingerprints, and signature_valid (openssl's own
    # `req -verify` - the real module asks cryptography's
    # is_signature_valid).
    #
    # Same deliberate divergence as the certificate half above:
    # extensions_by_oid, subject_key_identifier, authority_key_identifier
    # and the name_constraints_* fields are not returned (they need an
    # ASN.1 decoder this tree does not carry).
    def self.parse_csr(csr_pem : String) : Hash(String, JSON::Any)?
      pem_file = File.tempname("csrinfo")
      File.write(pem_file, csr_pem)
      begin
        text = run_openssl(["req", "-in", pem_file, "-noout", "-text"])
        return nil unless text

        names = run_openssl(["req", "-in", pem_file, "-noout", "-subject", "-nameopt", "lname"])
        pubkey_pem = run_openssl(["req", "-in", pem_file, "-noout", "-pubkey"])

        spki_der = nil
        if pubkey_pem
          pubkey_file = File.tempname("csrpub")
          File.write(pubkey_file, pubkey_pem)
          begin
            spki_der = der_bytes(["pkey", "-pubin", "-in", pubkey_file, "-outform", "DER"])
          ensure
            File.delete(pubkey_file) if File.exists?(pubkey_file)
          end
        end

        result = {} of String => JSON::Any
        parse_names(names, result)
        # the real csr_info has no issuer fields (a CSR carries none)
        result.delete("issuer")
        result.delete("issuer_ordered")
        parse_extensions(text, result)
        parse_public_key(pubkey_pem, spki_der, result)
        result["public_key_fingerprints"] = fingerprints_any(spki_der) if spki_der
        result["signature_valid"] = JSON::Any.new(signature_valid?(pem_file))

        # the real backend's extension getters return (None, False) for
        # every extension the request does not carry - the keys are
        # ALWAYS present, the values None
        # the real csr_info's key_usage is a LIST of usage strings; the
        # shared extension parser (matching the certificate half) emits
        # one comma-joined string
        if usage = result["key_usage"]?
          if usage_s = usage.as_s?
            result["key_usage"] = JSON::Any.new(usage_s.split(", ").map { |entry| JSON::Any.new(entry) })
          end
        end
        {"basic_constraints", "key_usage", "extended_key_usage",
         "ocsp_must_staple", "subject_alt_name"}.each do |key|
          result[key] = JSON::Any.new(nil) unless result.has_key?(key)
          result["#{key}_critical"] = JSON::Any.new(false) unless result.has_key?("#{key}_critical")
        end
        result["name_constraints_permitted"] = JSON::Any.new(nil) unless result.has_key?("name_constraints_permitted")
        result["name_constraints_excluded"] = JSON::Any.new(nil) unless result.has_key?("name_constraints_excluded")
        result["name_constraints_critical"] = JSON::Any.new(false) unless result.has_key?("name_constraints_critical")
        result["subject_key_identifier"] = JSON::Any.new(nil) unless result.has_key?("subject_key_identifier")
        result["authority_key_identifier"] = JSON::Any.new(nil) unless result.has_key?("authority_key_identifier")
        result["authority_cert_issuer"] = JSON::Any.new(nil) unless result.has_key?("authority_cert_issuer")
        result["authority_cert_serial_number"] = JSON::Any.new(nil) unless result.has_key?("authority_cert_serial_number")

        result
      ensure
        File.delete(pem_file) if File.exists?(pem_file)
      end
    end

    # The real csr_info get_info()'s own key order (community.crypto's
    # module_backends/csr_info.py CSRInfoRetrieval.get_info) - the
    # controller backfills failed/changed after these.
    CSR_INFO_KEY_ORDER = %w[
      subject subject_ordered key_usage key_usage_critical
      extended_key_usage extended_key_usage_critical basic_constraints
      basic_constraints_critical ocsp_must_staple ocsp_must_staple_critical
      subject_alt_name subject_alt_name_critical name_constraints_permitted
      name_constraints_excluded name_constraints_critical public_key
      public_key_type public_key_data public_key_fingerprints
      subject_key_identifier authority_key_identifier authority_cert_issuer
      authority_cert_serial_number extensions_by_oid signature_valid
    ]

    # parse_csr's output reordered into the real get_info() order, with
    # extensions_by_oid added - the shape both openssl_csr_info (as the
    # task result) and openssl_csr (as its diff's before/after payload)
    # must reproduce.
    def self.csr_info_ordered(csr_pem : String) : Hash(String, JSON::Any)?
      info = parse_csr(csr_pem)
      return nil unless info
      info["extensions_by_oid"] = JSON::Any.new(parse_extensions_by_oid(csr_pem))
      ordered = {} of String => JSON::Any
      CSR_INFO_KEY_ORDER.each do |key|
        ordered[key] = info[key] if info.has_key?(key)
      end
      info.each { |k, v| ordered[k] = v unless ordered.has_key?(k) }
      ordered
    end

    # The real module's extensions_by_oid:
    # cryptography_get_extensions_from_csr - {dotted_oid: {"critical":
    # bool, "value": base64(DER of the extension value)}}. The extension
    # value DER is exactly the content of each extension entry's
    # extnValue OCTET STRING, which `openssl asn1parse` prints verbatim
    # as a [HEX DUMP]. asn1parse only names known OIDs symbolically, so a
    # name table covers the standard X509v3 extensions and an already
    # dotted OBJECT passes through; names outside the table are skipped
    # (an unknown key would be wrong, a missing one merely incomplete).
    # Non-extension PKCS#9 request attributes (challengePassword etc.)
    # have the same SEQUENCE{OBJECT,OCTET STRING} shape - their OIDs are
    # excluded explicitly.
    EXTENSION_OID_NAMES = {
      "X509v3 Subject Alternative Name"     => "2.5.29.17",
      "X509v3 Issuer Alternative Name"      => "2.5.29.18",
      "X509v3 Basic Constraints"            => "2.5.29.19",
      "X509v3 Key Usage"                    => "2.5.29.15",
      "X509v3 Extended Key Usage"           => "2.5.29.37",
      "X509v3 Subject Key Identifier"       => "2.5.29.14",
      "X509v3 Authority Key Identifier"     => "2.5.29.35",
      "X509v3 CRL Distribution Points"      => "2.5.29.31",
      "X509v3 Freshest CRL"                 => "2.5.29.46",
      "X509v3 Authority Information Access" => "1.3.6.1.5.5.7.1.1",
      "X509v3 Subject Information Access"   => "1.3.6.1.5.5.7.1.11",
      "X509v3 Name Constraints"             => "2.5.29.30",
      "X509v3 Policy Constraints"           => "2.5.29.36",
      "X509v3 Certificate Policies"         => "2.5.29.32",
      "X509v3 Policy Mappings"              => "2.5.29.33",
      "X509v3 Inhibit Any-Policy"           => "2.5.29.54",
      "X509v3 CRL Number"                   => "2.5.29.20",
      "X509v3 Reason Code"                  => "2.5.29.21",
      "X509v3 Invalidity Date"              => "2.5.29.24",
      "OCSP No Check"                       => "1.3.6.1.5.5.7.48.1.5",
      "TLS Feature"                         => "1.3.6.1.5.5.7.1.24",
      "X509v3 Signed Certificate Timestamp" => "1.3.6.1.4.1.11129.2.4.2",
      "X509v3 Certificate Type"             => "2.16.840.1.113730.1.1",
      "X509v3 Netscape Cert Type"           => "2.16.840.1.113730.1.1",
      "X509v3 S/MIME Capabilities"          => "1.2.840.113549.1.9.15",
    }

    # Request attributes that share the extension shape but are not
    # X.509 extensions.
    NON_EXTENSION_OIDS = [
      "1.2.840.113549.1.9.7",  # challengePassword
      "1.2.840.113549.1.9.9",  # extensionRequest
      "1.2.840.113549.1.9.14", # extensionRequest (older spelling)
      "1.2.840.113549.1.9.3",  # contentType
      "1.2.840.113549.1.9.4",  # messageDigest
      "1.2.840.113549.1.9.26", # unstructuredName (pkcs9)
    ]

    def self.parse_extensions_by_oid(csr_pem : String) : Hash(String, JSON::Any)
      pem_file = File.tempname("csrext")
      File.write(pem_file, csr_pem)
      begin
        text = run_openssl(["asn1parse", "-in", pem_file]) || ""
      ensure
        File.delete(pem_file) if File.exists?(pem_file)
      end

      result = {} of String => JSON::Any
      last_oid : String? = nil
      last_oid_depth = -1
      critical = false
      text.each_line do |line|
        # "  348:d=7  hl=2 l=  24 prim: OCTET STRING      [HEX DUMP]:30..."
        md = line.match(/\A\s*(\d+):d=(\d+)\s+hl=\d+\s+l=\s*(\d+)\s+(prim|cons):\s*([A-Z0-9 ]+?)\s*(?::(.*))?\s*\z/)
        next unless md
        depth = md[2].to_i
        kind = md[4]
        type = md[5].strip
        value = md[6]?
        if kind == "prim" && type == "OBJECT"
          last_oid = value.try(&.strip)
          last_oid_depth = depth
          critical = false
        elsif kind == "prim" && type == "BOOLEAN" && depth == last_oid_depth + 1
          # a non-DEFAULT TRUE boolean prints ":255"
          critical = value.try(&.strip) == "255"
        elsif kind == "prim" && type == "OCTET STRING" && depth == last_oid_depth + 1 &&
              (hex = value.try { |v| v.starts_with?("[HEX DUMP]:") ? v["[HEX DUMP]:".size..] : nil })
          if oid = resolve_extension_oid(last_oid)
            der = slice_from_hex(hex)
            result[oid] = JSON::Any.new({
              "critical" => JSON::Any.new(critical),
              "value"    => JSON::Any.new(Base64.strict_encode(der)),
            }.to_h { |k, v| {k, v} })
          end
          last_oid = nil
          critical = false
        elsif kind == "cons"
          # entering a nested structure invalidates a dangling OBJECT only
          # if it went past the sibling depth the octet string would sit at
          last_oid = nil if depth > last_oid_depth + 1
        end
      end
      result
    rescue
      {} of String => JSON::Any
    end

    private def self.resolve_extension_oid(raw : String?) : String?
      return nil unless raw
      return nil if NON_EXTENSION_OIDS.includes?(raw)
      return raw if raw =~ /\A\d+(\.\d+)+\z/
      EXTENSION_OID_NAMES[raw]?
    end

    private def self.slice_from_hex(hex : String) : Bytes
      cleaned = hex.strip
      bytes = Bytes.new(cleaned.size // 2)
      bytes.size.times do |i|
        bytes[i] = cleaned[i * 2, 2].to_u8(16)
      end
      bytes
    end

    # `openssl req -verify` exits 0 and prints "verify OK" exactly when
    # the request's self-signature is valid - the CLI equivalent of
    # cryptography's is_signature_valid. WHICH stream carries the
    # message is openssl-version-dependent (3.0.x prints it on stderr,
    # 3.5.x on stdout), so both are checked - a stdout-only check
    # reported every valid request as signature_valid=false on the
    # openssl 3.0 hosts (this is what broke CI's x509 spec on the
    # Ubuntu 24.04 CI container while dev machines with 3.5 passed).
    private def self.signature_valid?(pem_file : String) : Bool
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", ["req", "-in", pem_file, "-noout", "-verify"], output: stdout_io, error: err)
      status.success? && (stdout_io.to_s.includes?("verify OK") || err.to_s.includes?("verify OK"))
    end

    def self.run_openssl(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      status.success? ? stdout_io.to_s : nil
    end

    def self.der_bytes(args : Array(String)) : Bytes?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      status.success? ? stdout_io.to_slice : nil
    end

    private def self.parse_version_and_signature(text : String, result : Hash(String, JSON::Any))
      if m = text.match(/Version:\s+(\d+)/)
        result["version"] = JSON::Any.new(m[1].to_i)
      end
      if m = text.match(/Signature Algorithm:\s*(\S+)/)
        result["signature_algorithm"] = JSON::Any.new(m[1])
      end
    end

    # -nameopt lname prints long names ("commonName = www.example.com"),
    # the same OpenSSL LN vocabulary the real module emits through
    # cryptography's OID table.
    private def self.parse_names(names : String?, result : Hash(String, JSON::Any))
      return unless names
      subject = {} of String => JSON::Any
      subject_ordered = [] of JSON::Any
      issuer = {} of String => JSON::Any
      issuer_ordered = [] of JSON::Any
      names.each_line do |line|
        kind = line.starts_with?("subject=") ? "subject" : line.starts_with?("issuer=") ? "issuer" : nil
        next unless kind
        eq = line.index!("=")
        body = line[(eq + 1)..]
        target_ordered = kind == "subject" ? subject_ordered : issuer_ordered
        target = kind == "subject" ? subject : issuer
        parse_name_pairs(body).each do |key, value|
          target_ordered << JSON::Any.new([JSON::Any.new(key), JSON::Any.new(value)])
          target[key] = JSON::Any.new(value)
        end
      end
      result["subject"] = JSON::Any.new(subject.to_h { |k, v| {k, v} })
      result["subject_ordered"] = JSON::Any.new(subject_ordered)
      result["issuer"] = JSON::Any.new(issuer.to_h { |k, v| {k, v} })
      result["issuer_ordered"] = JSON::Any.new(issuer_ordered)
    end

    private def self.parse_name_pairs(body : String) : Array(Tuple(String, String))
      pairs = [] of Tuple(String, String)
      body.split(", ").each do |pair|
        idx = pair.index(" = ") || pair.index("=")
        next unless idx
        eq = pair.index!("=")
        key = pair[0...idx].strip
        value = pair[(eq + 1)..].strip
        pairs << {key, value}
      end
      pairs
    end

    private def self.parse_validity(dates : String?, now : Time, result : Hash(String, JSON::Any))
      return unless dates
      not_before = nil
      not_after = nil
      dates.each_line do |line|
        if line.starts_with?("notBefore=")
          not_before = parse_openssl_date(line["notBefore=".size..])
        elsif line.starts_with?("notAfter=")
          not_after = parse_openssl_date(line["notAfter=".size..])
        end
      end
      result["not_before"] = JSON::Any.new(not_before) if not_before
      result["not_after"] = JSON::Any.new(not_after) if not_after
      if na = not_after
        result["expired"] = JSON::Any.new(parse_asn1_time(na) < now)
      end
    end

    # "Apr 13 20:24:28 2019 GMT" -> "20190413202428Z", the ASN.1 TIME
    # spelling the real module returns.
    private def self.parse_openssl_date(raw : String) : String
      cleaned = raw.strip
      begin
        t = Time.parse(cleaned, "%b %d %H:%M:%S %Y %Z", Time::Location::UTC)
        t.to_s("%Y%m%d%H%M%SZ")
      rescue Time::Format::Error
        cleaned
      end
    end

    private def self.parse_asn1_time(value : String) : Time
      Time.parse(value, "%Y%m%d%H%M%SZ", Time::Location::UTC)
    rescue
      Time.utc
    end

    private def self.parse_serial(serial : String?, result : Hash(String, JSON::Any))
      return unless serial
      if m = serial.match(/serial=([0-9a-fA-F]+)/i)
        hex = m[1]
        hex = hex[1..] if hex.size.odd?
        decimal = big_hex_to_decimal(hex)
        result["serial_number"] = json_int(decimal)
      end
    rescue
      # A serial wider than hex arithmetic here can handle stays absent
      # rather than wrong.
    end

    private def self.parse_extensions(text : String, result : Hash(String, JSON::Any))
      extension_section(text).try do |entries|
        entries.each do |header, body|
          critical = header.ends_with?("critical")
          name = header.sub(/:\s*critical\s*$/, "").sub(/:\s*$/, "").strip
          case name
          when "X509v3 Basic Constraints"
            list = body.split(",").map(&.strip).reject(&.empty?)
            result["basic_constraints"] = JSON::Any.new(list.sort.map { |e| JSON::Any.new(e) })
            result["basic_constraints_critical"] = JSON::Any.new(critical)
          when "X509v3 Key Usage"
            list = body.split(",").map(&.strip).reject(&.empty?).sort!
            result["key_usage"] = JSON::Any.new(list.join(", "))
            result["key_usage_critical"] = JSON::Any.new(critical)
          when "X509v3 Extended Key Usage"
            list = body.split(",").map(&.strip).reject(&.empty?).sort!
            result["extended_key_usage"] = JSON::Any.new(list.map { |e| JSON::Any.new(e) })
            result["extended_key_usage_critical"] = JSON::Any.new(critical)
          when "X509v3 Subject Alternative Name"
            list = body.split(",").map(&.strip).reject(&.empty?).map { |e| decode_san_entry(e) }
            result["subject_alt_name"] = JSON::Any.new(list.map { |e| JSON::Any.new(e) })
            result["subject_alt_name_critical"] = JSON::Any.new(critical)
          when "X509v3 TLS Feature", "1.3.6.1.5.5.7.1.24"
            result["ocsp_must_staple"] = JSON::Any.new(body.includes?("Status Request"))
            result["ocsp_must_staple_critical"] = JSON::Any.new(critical)
          when "X509v3 Subject Key Identifier"
            result["subject_key_identifier"] = JSON::Any.new(body.split("
").first.to_s.strip)
          when "X509v3 Authority Key Identifier"
            keyid = body.split("
").map(&.strip).find(&.starts_with?("keyid:"))
            aki = keyid ? keyid.lchop("keyid:").strip : nil
            result["authority_key_identifier"] = JSON::Any.new(aki)
            # issuer/serial-number forms (dirName, serial) need deeper
            # ASN.1 reading; nothing in the corpus generates them
            result["authority_cert_issuer"] = JSON::Any.new(nil)
            result["authority_cert_serial_number"] = JSON::Any.new(nil)
          when "X509v3 Name Constraints"
            permitted = [] of JSON::Any
            excluded = [] of JSON::Any
            target = nil
            body.split("
").map(&.strip).each do |line|
              target = permitted if line == "Permitted:"
              target = excluded if line == "Excluded:"
              next if line.empty? || line == "Permitted:" || line == "Excluded:"
              target.try(&.<<(JSON::Any.new(line)))
            end
            result["name_constraints_permitted"] = JSON::Any.new(permitted)
            result["name_constraints_excluded"] = JSON::Any.new(excluded)
            result["name_constraints_critical"] = JSON::Any.new(critical)
          end
        end
      end
    end

    # The real module renders SAN entries through cryptography's name
    # map - "IP:1.2.3.4", not openssl's "IP Address:1.2.3.4", "RID:" not
    # "Registered ID:". Everything else (DNS/email/URI) already matches.
    private def self.decode_san_entry(entry : String) : String
      entry.sub(/\AIP Address:/, "IP:").sub(/\ARegistered ID:/, "RID:")
    end

    # The "X509v3 extensions:" section of `openssl x509 -text`: a list of
    # (extension header, body text) pairs. The section header sits at
    # indent 8, each extension's own header at indent 12, and bodies
    # deeper still - so "one level below the section header" identifies
    # extension names reliably. A header may carry a trailing
    # " critical" marker ("X509v3 Basic Constraints: critical").
    private def self.extension_section(text : String) : Array(Tuple(String, String))?
      # certificates carry the section header "X509v3 extensions:";
      # a CSR's `openssl req -text` spells it "Requested Extensions:"
      idx = text.index("X509v3 extensions:") || text.index("Requested Extensions:")
      return nil unless idx
      section_line_start = text.rindex('\n', idx).try { |pos| pos + 1 } || 0
      name_indent = (idx - section_line_start) + 4
      marker = text.index("X509v3 extensions:") == idx ? "X509v3 extensions:" : "Requested Extensions:"
      section = text[(idx + marker.size)..]
      entries = [] of Tuple(String, String)
      current_name = nil
      current_body = IO::Memory.new
      section.each_line do |line|
        stripped = line.strip
        next if stripped.empty?
        indent = line.size - line.lstrip.size
        # Anything dedented back to the section's own level (openssl's
        # trailing "Signature Algorithm:"/"Signature Value:" block) ends
        # the extension section.
        break if indent < name_indent
        is_header = indent == name_indent &&
                    stripped.matches?(/^(X509v3 [^:]+|[0-9a-fA-F]+(\.[0-9a-fA-F]+)+)(: critical|:)$/)
        if is_header
          if current_name
            entries << {current_name, current_body.to_s.strip}
          end
          current_name = stripped
          current_body.clear
        elsif current_name
          current_body << stripped << "\n"
        end
      end
      if current_name
        entries << {current_name, current_body.to_s.strip}
      end
      entries
    end

    private def self.parse_public_key(pubkey_pem : String?, spki_der : Bytes?, result : Hash(String, JSON::Any))
      result["public_key"] = JSON::Any.new(pubkey_pem) if pubkey_pem
      return unless spki_der

      key_text = nil
      if pubkey_pem
        tmp = File.tempname("x509pubtxt")
        File.write(tmp, pubkey_pem)
        begin
          key_text = run_openssl(["pkey", "-pubin", "-in", tmp, "-noout", "-text"])
        ensure
          File.delete(tmp) if File.exists?(tmp)
        end
      end
      key_type, key_data = classify_public_key(key_text || "")
      result["public_key_type"] = JSON::Any.new(key_type)
      result["public_key_data"] = JSON::Any.new(key_data.to_h { |k, v| {k, v} })
    end

    # Reads the same openssl -text shapes the real module's Python
    # backend reads from cryptography objects: RSA gives size/modulus/
    # exponent, ECC gives curve/x/y/exponent_size, Ed25519/X25519 etc.
    # give an empty public_data dict.
    def self.classify_public_key(text : String) : Tuple(String, Hash(String, JSON::Any))
      data = {} of String => JSON::Any
      # openssl 3 prints the PRIVATE key's modulus lowercase
      # ("modulus:"), the PUBLIC one capitalized ("Modulus:") - both
      # mean the same field.
      if text.matches?(/modulus:/i)
        size = text.match(/(Public|Private)-Key:\s*\((\d+) bit/).try(&.[2].to_i)
        data["size"] = JSON::Any.new(size || 0) if size
        data["modulus"] = parse_hex_int_block(text, "modulus")
        if exponent = parse_exponent(text)
          data["exponent"] = exponent
        end
        return {"RSA", data}
      end
      if m = text.match(/ASN1 OID:\s*(\S+)/)
        size = text.match(/(Public|Private)-Key:\s*\((\d+) bit/).try(&.[2].to_i)
        data["curve"] = JSON::Any.new(m[1])
        data["exponent_size"] = JSON::Any.new(size || 0) if size
        if coords = parse_ec_point(text, size)
          data["x"] = coords[0]
          data["y"] = coords[1]
        end
        return {"ECC", data}
      end
      if m = text.match(/(Ed25519|Ed448|X25519|X448)\s+Public-Key/i)
        return {m[1], data}
      end
      if text.includes?("DSA Public-Key") || text.includes?("DSA public key")
        # DSA's p/q/g/y parsing is not worth the text-format risk for a
        # key type nothing in the corpus generates; report the type only.
        size = text.match(/(Public|Private)-Key:\s*\((\d+) bit/).try(&.[2].to_i)
        data["size"] = JSON::Any.new(size || 0) if size
        return {"DSA", data}
      end
      {"unknown", data}
    end

    private def self.parse_hex_int_block(text : String, header : String) : JSON::Any
      hex = hex_block_after(text, header)
      json_int(big_hex_to_decimal(hex))
    end

    # Public wrapper for the private-key modules: the decimal value of a
    # labeled hex block ("prime1:", "priv:", ...) as a JSON int-or-string.
    def self.labeled_hex_value(text : String, header : String) : JSON::Any?
      hex = hex_block_after(text, header)
      return nil if hex.empty?
      json_int(big_hex_to_decimal(hex))
    end

    private def self.parse_exponent(text : String) : JSON::Any?
      if m = text.match(/Exponent:\s*(\d+)/)
        JSON::Any.new(m[1].to_i)
      end
    end

    # Collects the hex lines following a labeled block ("modulus:",
    # "pub:", "prime1:") until a non-hex line ends it. openssl prints
    # the bytes colon-separated and wrapped; both are stripped here.
    private def self.hex_block_after(text : String, header : String) : String
      hex_lines = [] of String
      capture = false
      text.each_line do |line|
        stripped = line.strip
        if !capture && stripped.downcase.starts_with?(header.downcase)
          capture = true
          next
        end
        next unless capture
        break unless stripped.delete(':').matches?(/^[0-9a-fA-f]+$/)
        hex_lines << stripped.delete(':')
      end
      hex_lines.join
    end

    # The uncompressed point form (04 || X || Y) that the "pub:" hex
    # block holds for an ECC key.
    private def self.parse_ec_point(text : String, size : Int32?) : Tuple(JSON::Any, JSON::Any)?
      hex = hex_block_after(text, "pub:")
      return nil unless size && hex.size >= 2
      bytes = hex.hexbytes
      return nil unless bytes[0]? == 4
      coordinate_bytes = (size / 8).ceil.to_i
      x = bytes[1, coordinate_bytes]
      y = bytes[1 + coordinate_bytes, coordinate_bytes]
      return nil unless x.size == coordinate_bytes && y.size == coordinate_bytes
      {json_int(big_hex_to_decimal(x.hexstring)), json_int(big_hex_to_decimal(y.hexstring))}
    end
  end
end
