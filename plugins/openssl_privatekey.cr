#!/usr/bin/env crystal

require "json"
require "openssl"
require "../src/krikri/base_plugin"

module Krikri
  # openssl_privatekey plugin (community.crypto.openssl_privatekey) -
  # generates TLS/SSL private keys.
  #
  # Backed by the `openssl` CLI, the same approach `openssl_dhparam.cr`
  # already takes here: the real module dropped its own openssl-CLI
  # backend in favour of Python's `cryptography` library, but the file
  # formats it produces (PKCS#1/PKCS#8/raw, optionally encrypted) are
  # standard, so the CLI reproduces them exactly - and there is no
  # Python runtime on the target to lean on. Every behavior below was
  # differentialed against the real module (community.crypto 3.1.1,
  # ansible-core 2.19.4) rather than read off the docs alone, including
  # the idempotency matrix, which is the part roles actually depend on:
  #
  #   existing key, same type/size          -> ok (no change)
  #   size or type differs                  -> regenerated (changed)
  #   wrong passphrase / none / unexpected  -> regenerated (changed),
  #                                            NOT a failure, under the
  #                                            default full_idempotence
  #   regenerate: never + mismatch          -> ok (no change)
  #   format: pkcs8 over an existing pkcs1  -> regenerated (changed);
  #                                            format_mismatch: convert
  #                                            converts in place instead
  #   default format (auto_ignore)          -> an existing key's format
  #                                            is never held against it
  #
  # Parameters: path (required), state, force, backup, size, type,
  # curve, passphrase, cipher, format, format_mismatch, regenerate,
  # return_content, owner/group/mode, check_mode. select_crypto_backend
  # is accepted and ignored (there is only one backend here).
  class OpensslPrivatekeyPlugin < BasePlugin
    # community.crypto names curves per the IANA TLS registry; the
    # openssl CLI wants its own name for exactly one of them
    # (`secp256r1` is `prime256v1` there, and `genpkey` rejects the IANA
    # spelling outright rather than aliasing it). Every other curve
    # below is spelled identically by both, and is listed anyway so an
    # unsupported name fails with the real module's own error text
    # rather than a raw openssl one.
    CURVE_ALIASES = {
      "secp256r1" => "prime256v1",
      "secp192r1" => "prime192v1",
    }

    # Order matters: it is printed verbatim in the "value of curve must
    # be one of: ..." failure message, which is matched against the real
    # module's own argspec error.
    KNOWN_CURVES = %w[
      secp224r1 secp256k1 secp256r1 secp384r1 secp521r1 secp192r1
      brainpoolP256r1 brainpoolP384r1 brainpoolP512r1
      sect163k1 sect163r2 sect233k1 sect233r1 sect283k1 sect283r1
      sect409k1 sect409r1 sect571k1 sect571r1
    ]

    EDWARDS_TYPES = %w[Ed25519 Ed448 X25519 X448]

    def execute : PluginResult
      path = @params["path"]?
      return failure("state is present but all of the following are missing: path") unless path

      path = expand_tilde(path)
      state = @params["state"]? || "present"
      check_mode = true?(@params["check_mode"]?)

      return remove(path, check_mode) if state == "absent"

      type = @params["type"]? || "RSA"
      size = (@params["size"]? || "4096").to_i
      curve = @params["curve"]?
      passphrase = @params["passphrase"]?
      cipher = @params["cipher"]? || "auto"
      format = @params["format"]? || "auto_ignore"
      format_mismatch = @params["format_mismatch"]? || "regenerate"
      regenerate = @params["regenerate"]? || "full_idempotence"
      force = true?(@params["force"]?)

      handle_present(path, type, size, curve, passphrase, cipher, format,
        format_mismatch, regenerate, force)
    end

    private def handle_present(path : String, type : String, size : Int32, curve : String?,
                               passphrase : String?, cipher : String, format : String,
                               format_mismatch : String, regenerate : String, force : Bool) : PluginResult
      if error = curve_failure(type, curve)
        return error
      end

      base_dir = File.dirname(path)
      unless Dir.exists?(base_dir)
        return failure("The directory #{base_dir} does not exist or the file is not a directory")
      end

      existing = File.exists?(path)
      # Mirrors PrivateKeyBackend#needs_regeneration exactly, including
      # the order of its checks - the passphrase check comes first and
      # short-circuits the type/size one, because a key that cannot be
      # decrypted cannot be inspected either.
      regen = false
      if force || regenerate == "always" || !existing
        regen = true
      else
        outcome = passphrase_and_size_outcome(path, passphrase, type, size, curve, regenerate)
        return outcome if outcome.is_a?(PluginResult)
        regen = outcome == true

        outcome = format_outcome(regen, format_mismatch, path, type, format, regenerate)
        return outcome if outcome.is_a?(PluginResult)
        regen = true if outcome == true
      end

      convert = convert_needed?(regen, existing, format_mismatch, path, type, format)
      return write_key(regen, convert, path, type, size, curve, passphrase, cipher, format) if regen || convert

      # No regeneration needed - owner/group/mode drift is still a real
      # change, exactly as the real module reports it (it runs the file
      # attribute step unconditionally).
      changed = apply_attrs(path, default_mode: true)
      result(changed, path, type, size, curve, nil)
    end

    private def curve_failure(type : String, curve : String?) : PluginResult?
      return nil unless type == "ECC"
      return failure("curve must be specified for type=ECC") unless curve
      unless KNOWN_CURVES.includes?(curve)
        return failure("value of curve must be one of: #{KNOWN_CURVES.join(", ")}, got: #{curve}")
      end
      nil
    end

    private def passphrase_and_size_outcome(path : String, passphrase : String?, type : String,
                                            size : Int32, curve : String?,
                                            regenerate : String) : PluginResult | Bool
      unless passphrase_ok?(path, passphrase)
        return failure("Unable to read the key. The key is protected with a another passphrase / no passphrase or broken." \
                       " Will not proceed. To force regeneration, call the module with `generate`" \
                       " set to `full_idempotence` or `always`, or with `force=true`.") unless regenerate == "full_idempotence"
        return true
      end

      return false if regenerate == "never" || size_and_type_match?(path, passphrase, type, size, curve)
      return failure("Key has wrong type and/or size." \
                     " Will not proceed. To force regeneration, call the module with `generate`" \
                     " set to `partial_idempotence`, `full_idempotence` or `always`, or with `force=true`.") unless ["partial_idempotence", "full_idempotence"].includes?(regenerate)
      true
    end

    private def format_outcome(regen : Bool, format_mismatch : String, path : String,
                               type : String, format : String, regenerate : String) : PluginResult | Bool
      return false if regen || format_mismatch != "regenerate" || regenerate == "never"
      return false if format_matches?(path, type, format)
      return failure("Key has wrong format." \
                     " Will not proceed. To force regeneration, call the module with `generate`" \
                     " set to `partial_idempotence`, `full_idempotence` or `always`, or with `force=true`." \
                     " To convert the key, set `format_mismatch` to `convert`.") unless ["partial_idempotence", "full_idempotence"].includes?(regenerate)
      true
    end

    private def convert_needed?(regen : Bool, existing : Bool, format_mismatch : String,
                                path : String, type : String, format : String) : Bool
      !regen && existing && format_mismatch == "convert" && !format_matches?(path, type, format)
    end

    private def write_key(regen : Bool, convert : Bool, path : String, type : String, size : Int32,
                          curve : String?, passphrase : String?, cipher : String, format : String) : PluginResult
      return result(true, path, type, size, curve, nil) if true?(@params["check_mode"]?)

      backup_file = backup(path)
      error = regen ? generate(path, type, size, curve, passphrase, cipher, format) : convert_format(path, type, passphrase, cipher, format)
      return failure(error) if error

      apply_attrs(path, default_mode: true)
      result(true, path, type, size, curve, backup_file)
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    private def result(changed : Bool, path : String, type : String, size : Int32,
                       curve : String?, backup_file : String?) : PluginResult
      extra = {} of String => JSON::Any
      extra["filename"] = JSON::Any.new(path)
      extra["size"] = JSON::Any.new(size.to_i64)
      extra["type"] = JSON::Any.new(type)
      extra["curve"] = JSON::Any.new(curve) if type == "ECC" && curve
      extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      if fp = fingerprints(path)
        extra["fingerprint"] = JSON::Any.new(fp)
      end
      if true?(@params["return_content"]?) && File.exists?(path)
        extra["privatekey"] = JSON::Any.new(File.read(path))
      end

      res = PluginResult.new(changed: changed, failed: false, msg: "")
      extra.each { |k, v| res.extra[k] = v }
      res
    end

    private def remove(path : String, check_mode : Bool) : PluginResult
      exists = File.exists?(path)
      backup_file = nil
      if exists && !check_mode
        backup_file = backup(path)
        File.delete(path)
      end

      res = PluginResult.new(changed: exists, failed: false, msg: "")
      res.extra["filename"] = JSON::Any.new(path)
      res.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      res
    end

    # --- existing-key inspection -------------------------------------

    private def encrypted?(path : String) : Bool
      return false if raw_file?(path)
      head = File.read(path)[0, 200]? || ""
      head.includes?("ENCRYPTED")
    rescue
      false
    end

    # True when the key can be read with exactly the passphrase given -
    # which includes the negative direction: a passphrase supplied for
    # an unencrypted key is a mismatch to the real module too (Python's
    # `cryptography` raises "Password was given but private key is not
    # encrypted"), not a harmless extra.
    private def passphrase_ok?(path : String, passphrase : String?) : Bool
      # Raw key material is never encrypted (the format has nowhere to
      # put the encryption metadata), so "no passphrase wanted" is the
      # only passing combination.
      return passphrase.nil? || passphrase.empty? if raw_file?(path)

      enc = encrypted?(path)
      return false if enc && (passphrase.nil? || passphrase.empty?)
      return false if !enc && passphrase && !passphrase.empty?
      read_key_text(path, passphrase) != nil
    end

    private def read_key_text(path : String, passphrase : String?) : String?
      args = ["pkey", "-in", path, "-noout", "-text"]
      args.concat(["-passin", "pass:#{passphrase}"]) if passphrase && !passphrase.empty?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      status.success? ? stdout_io.to_s : nil
    end

    private def size_and_type_match?(path : String, passphrase : String?, type : String,
                                     size : Int32, curve : String?) : Bool
      # A `format: raw` key on disk is bare key material - no PEM, no
      # DER, nothing for `openssl pkey` to parse and nothing that
      # records its own type. All that can be checked is that its length
      # is the one this type produces, which is what the real module
      # effectively does too (it loads the bytes AS the configured type).
      if raw_file?(path)
        return false unless EDWARDS_TYPES.includes?(type)
        return File.size(path) == raw_size(type)
      end

      text = read_key_text(path, passphrase)
      return false unless text

      case type
      when "RSA", "DSA" then rsa_dsa_match?(text, type, size)
      when "ECC"        then ecc_match?(text, curve)
      when "Ed25519", "Ed448", "X25519", "X448"
        text.upcase.includes?("#{type.upcase} PRIVATE-KEY")
      else
        false
      end
    end

    private def rsa_dsa_match?(text : String, type : String, size : Int32) : Bool
      return false unless text.includes?("#{type} Private-Key") || text.matches?(/^Private-Key: \(\d+ bit/m)
      return false if type == "RSA" && text.includes?("DSA")
      return false if type == "DSA" && !text.includes?("DSA")
      if match = text.match(/Private-Key: \((\d+) bit/)
        match[1].to_i == size
      else
        false
      end
    end

    private def ecc_match?(text : String, curve : String?) : Bool
      return false unless text.includes?("ASN1 OID") || text.includes?("EC Private-Key")
      openssl_curve = CURVE_ALIASES[curve]? || curve
      text.includes?("ASN1 OID: #{openssl_curve}")
    end

    # The format a NEW key of this type would be written in when the
    # user asked for `auto`/`auto_ignore` - PrivateKeyBackend#
    # _get_effective_format: pkcs8 for the Edwards/montgomery curves
    # (they have no traditional serialization), pkcs1 for everything
    # else.
    private def effective_format(type : String, format : String) : String
      return format unless format == "auto" || format == "auto_ignore"
      EDWARDS_TYPES.includes?(type) ? "pkcs8" : "pkcs1"
    end

    # True when the file is not PEM - i.e. raw key material. Read as
    # bytes, never as a String: raw key material is not valid UTF-8, and
    # File.read raises on it (which previously fell into the rescue
    # below and reported "format does not match", regenerating a
    # perfectly good raw key on every single run).
    private def raw_file?(path : String) : Bool
      return false unless File.exists?(path)
      marker = "-----BEGIN".to_slice
      header = File.open(path) do |file|
        buffer = Bytes.new(marker.size)
        read = file.read(buffer)
        buffer[0, read]
      end
      header != marker
    rescue
      false
    end

    private def raw_size(type : String) : Int32
      case type
      when "Ed448" then 57
      when "X448"  then 56
      else              32
      end
    end

    private def format_matches?(path : String, type : String, format : String) : Bool
      # auto_ignore deliberately accepts whatever is already on disk -
      # this is the DEFAULT, so an existing key is never regenerated for
      # its format alone unless the user asked for a specific one.
      return true if format == "auto_ignore"

      wanted = effective_format(type, format)
      return raw_file?(path) if wanted == "raw"

      head = (File.read(path)[0, 100]? || "").lines.first? || ""
      pem_head_matches?(head, wanted)
    rescue
      false
    end

    private def pem_head_matches?(head : String, wanted : String) : Bool
      case wanted
      when "pkcs8"
        head.includes?("BEGIN PRIVATE KEY") || head.includes?("BEGIN ENCRYPTED PRIVATE KEY")
      when "pkcs1"
        head.includes?("BEGIN RSA PRIVATE KEY") || head.includes?("BEGIN EC PRIVATE KEY") ||
          head.includes?("BEGIN DSA PRIVATE KEY")
      else
        true
      end
    end

    # --- generation ---------------------------------------------------

    private def cipher_flag(cipher : String) : String
      # `auto` is the real module's default and means "the best
      # available encryption", which for `cryptography` is AES-256-CBC -
      # verified against a real module run (`DEK-Info: AES-256-CBC`).
      return "-aes256" if cipher == "auto" || cipher.empty?
      "-#{cipher}"
    end

    # Every temporary file below is created NEXT TO the destination, not
    # in /tmp: the final step is a rename, which only works within one
    # filesystem, and key material must never be written somewhere with
    # weaker permissions than the destination directory. The file is
    # pre-created 0600 and openssl told to write into it (`-out`
    # truncates, it does not re-create), so the key is never briefly
    # world-readable.
    private def secure_tempfile(near : String, prefix : String) : String
      path = File.tempname(prefix, dir: File.dirname(near))
      File.write(path, "")
      File.chmod(path, 0o600)
      path
    end

    private def generate(path : String, type : String, size : Int32, curve : String?,
                         passphrase : String?, cipher : String, format : String) : String?
      raw_key = secure_tempfile(path, "privatekey")
      begin
        if error = generate_raw(raw_key, type, size, curve)
          return error
        end
        serialize(raw_key, path, type, passphrase, cipher, effective_format(type, format))
      ensure
        File.delete(raw_key) if File.exists?(raw_key)
      end
    end

    private def generate_raw(out_path : String, type : String, size : Int32, curve : String?) : String?
      case type
      when "RSA"
        run_openssl(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:#{size}", "-out", out_path])
      when "DSA"
        # DSA needs its parameters generated first; `genpkey -genparam`
        # then `genpkey -paramfile` is the CLI equivalent of
        # `dsa.generate_private_key(key_size=...)`.
        params = secure_tempfile(out_path, "dsaparam")
        begin
          if error = run_openssl(["genpkey", "-genparam", "-algorithm", "DSA",
                                  "-pkeyopt", "dsa_paramgen_bits:#{size}", "-out", params])
            return error
          end
          run_openssl(["genpkey", "-paramfile", params, "-out", out_path])
        ensure
          File.delete(params) if File.exists?(params)
        end
      when "ECC"
        openssl_curve = CURVE_ALIASES[curve]? || curve
        run_openssl(["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:#{openssl_curve}", "-out", out_path])
      when "Ed25519", "Ed448", "X25519", "X448"
        run_openssl(["genpkey", "-algorithm", type.upcase, "-out", out_path])
      else
        "value of type must be one of: DSA, ECC, Ed25519, Ed448, RSA, X25519, X448, got: #{type}"
      end
    end

    # Writes *src* (always PKCS#8, as `genpkey` produces) out to *dest*
    # in the requested format, encrypting when a passphrase is set.
    private def serialize(src : String, dest : String, type : String, passphrase : String?,
                          cipher : String, format : String) : String?
      tmp = secure_tempfile(dest, "privatekey-out")
      begin
        args =
          case format
          when "pkcs8"
            ["pkey", "-in", src, "-out", tmp]
          when "raw"
            return write_raw(src, dest, type)
          else
            # pkcs1 - the traditional per-algorithm serialization. On
            # OpenSSL 3 `openssl rsa` defaults to PKCS#8 output, so
            # `-traditional` is required to get "BEGIN RSA PRIVATE KEY"
            # back; `openssl ec`/`openssl dsa` still default to their
            # traditional forms and reject the flag.
            case type
            when "RSA" then ["rsa", "-in", src, "-traditional", "-out", tmp]
            when "DSA" then ["dsa", "-in", src, "-out", tmp]
            when "ECC" then ["ec", "-in", src, "-out", tmp]
            else            ["pkey", "-in", src, "-out", tmp]
            end
          end

        if passphrase && !passphrase.empty?
          args.concat([cipher_flag(cipher), "-passout", "pass:#{passphrase}"])
        end

        if error = run_openssl(args)
          return error
        end
        File.rename(tmp, dest)
        nil
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end

    # `format: raw` for the Edwards/montgomery types: the bare key
    # bytes, no PEM, no DER wrapper. They are the tail of the PKCS#8
    # DER encoding (a fixed-size header followed by the key itself), so
    # slicing that off reproduces `private_bytes(Encoding.Raw)` exactly
    # - verified byte-for-byte against the real module's output.
    private def write_raw(src : String, dest : String, type : String) : String?
      return "format: raw is only supported for Ed25519, Ed448, X25519 and X448 keys" unless EDWARDS_TYPES.includes?(type)

      der = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", ["pkey", "-in", src, "-outform", "DER"], output: der, error: err)
      return "openssl pkey failed: #{err}" unless status.success?

      bytes = der.to_slice
      size = raw_size(type)
      return "unexpected DER length #{bytes.size} for a #{type} key" if bytes.size < size
      File.write(dest, bytes[bytes.size - size, size])
      nil
    end

    private def convert_format(path : String, type : String, passphrase : String?,
                               cipher : String, format : String) : String?
      src = secure_tempfile(path, "privatekey-src")
      begin
        args = ["pkey", "-in", path, "-out", src]
        args.concat(["-passin", "pass:#{passphrase}"]) if passphrase && !passphrase.empty?
        if error = run_openssl(args)
          return error
        end
        serialize(src, path, type, passphrase, cipher, effective_format(type, format))
      ensure
        File.delete(src) if File.exists?(src)
      end
    end

    private def run_openssl(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      return nil if status.success?
      "openssl #{args.first} failed: #{err.to_s.strip}"
    end

    # --- reporting ----------------------------------------------------

    # The real module fingerprints the PUBLIC key's DER
    # (SubjectPublicKeyInfo), colon-separated lowercase hex, over every
    # hashlib algorithm it can - verified: sha256 here equals the
    # module's own `fingerprint.sha256` for the same key.
    private def fingerprints(path : String) : Hash(String, JSON::Any)?
      return nil unless File.exists?(path)
      # No public key can be derived from bare raw bytes without knowing
      # the algorithm; the real module returns no fingerprint here either.
      return nil if raw_file?(path)

      args = ["pkey", "-in", path, "-pubout", "-outform", "DER"]
      if (passphrase = @params["passphrase"]?) && !passphrase.empty?
        args.concat(["-passin", "pass:#{passphrase}"])
      end
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      return nil unless status.success?

      der = stdout_io.to_slice
      result = {} of String => JSON::Any
      {
        "md5"      => "MD5",
        "sha1"     => "SHA1",
        "sha224"   => "SHA224",
        "sha256"   => "SHA256",
        "sha384"   => "SHA384",
        "sha512"   => "SHA512",
        "sha3_224" => "SHA3-224",
        "sha3_256" => "SHA3-256",
        "sha3_384" => "SHA3-384",
        "sha3_512" => "SHA3-512",
        "blake2b"  => "BLAKE2b512",
        "blake2s"  => "BLAKE2s256",
      }.each do |name, algorithm|
        if hex = colon_digest(der, algorithm)
          result[name] = JSON::Any.new(hex)
        end
      end

      # The two XOFs have no fixed digest size, so `OpenSSL::Digest`
      # cannot produce them; Python's hashlib is asked for 32 bytes of
      # output, which `openssl dgst -xoflen 32` reproduces byte for byte
      # (verified against the real module's own shake_128/shake_256).
      # Silently skipped where the CLI is too old to know -xoflen rather
      # than failing the task over a reporting field.
      {"shake_128" => "shake128", "shake_256" => "shake256"}.each do |name, algorithm|
        if hex = shake_digest(der, algorithm)
          result[name] = JSON::Any.new(hex)
        end
      end

      result.empty? ? nil : result
    rescue
      nil
    end

    private def shake_digest(data : Bytes, algorithm : String) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", ["dgst", "-#{algorithm}", "-xoflen", "32", "-c"],
        input: IO::Memory.new(data), output: stdout_io, error: err)
      return nil unless status.success?
      stdout_io.to_s.split("= ").last?.try(&.strip)
    rescue
      nil
    end

    private def colon_digest(data : Bytes, algorithm : String) : String?
      digest = OpenSSL::Digest.new(algorithm)
      digest.update(data)
      digest.final.to_slice.map(&.to_s(16).rjust(2, '0')).join(":")
    rescue
      nil
    end

    private def apply_attrs(path : String, default_mode : Bool = false) : Bool
      return false unless File.exists?(path)
      before = File.info(path).permissions.value
      mode = @params["mode"]?
      # "It will have 0600 mode if mode is not explicitly set" - the
      # module's own documented default for this file, not the umask.
      mode = "0600" if mode.nil? && default_mode
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, mode)
      File.info(path).permissions.value != before
    rescue
      false
    end

    # Real Ansible's backup_local: "<path>.<pid>.<YYYY-MM-DD@HH:MM:SS>~"
    private def backup(path : String) : String?
      return nil unless true?(@params["backup"]?)
      return nil unless File.exists?(path)
      dest = "#{path}.#{Process.pid}.#{Time.local.to_s("%Y-%m-%d@%H:%M:%S")}~"
      File.copy(path, dest)
      dest
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::OpensslPrivatekeyPlugin.new(config)
plugin.run
