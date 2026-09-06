require "json"
require "openssl/digest"

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
  # Deliberately not implemented (nothing in the role corpus reads them):
  # `extensions_by_oid` (the DER-encoded value of every extension - needs
  # an ASN.1 decoder this tree does not carry). The field is omitted from
  # the result rather than emitted empty, and noted in KNOWN_MISSING.md.
  module X509CertInfo
    # hashlib.algorithms_guaranteed minus the two SHAKE XOFs, which
    # OpenSSL exposes only with a caller-chosen output length and
    # Crystal's Digest does not surface - everything else is emitted
    # under the real module's Python algorithm names.
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
      result
    rescue
      {} of String => JSON::Any
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
      idx = text.index("X509v3 extensions:")
      return nil unless idx
      section_line_start = text.rindex('\n', idx).try { |pos| pos + 1 } || 0
      name_indent = (idx - section_line_start) + 4
      section = text[(idx + "X509v3 extensions:".size)..]
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
