#!/usr/bin/env crystal

require "json"
require "openssl"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/openssl_pkey"

module Krikri
  # openssl_privatekey plugin (community.crypto.openssl_privatekey) -
  # generates TLS/SSL private keys.
  #
  # Backed by libcrypto's own EVP keygen/serialization (see
  # `plugin_helpers/openssl_pkey.cr`): the Ansible module dropped its own
  # openssl-CLI backend in favour of Python's `cryptography` library, and
  # this plugin does the equivalent natively - there is no Python runtime
  # on the target, and the `openssl` CLI binary is absent from minimal
  # containers, which made every generation die with "Error executing
  # process: 'openssl': No such file or directory". The file formats it
  # produces (PKCS#1/PKCS#8/raw, optionally encrypted) are standard.
  # Every behavior below was
  # differentialed against the Ansible module (community.crypto 3.1.1,
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
    Pkey      = PluginHelpers::Pkey
    NID_RSA   = PluginHelpers::Pkey::NID_RSA
    NID_DSA   = PluginHelpers::Pkey::NID_DSA
    NID_EC    = PluginHelpers::Pkey::NID_EC
    TYPE_NIDS = PluginHelpers::Pkey::TYPE_NIDS

    # community.crypto names curves per the IANA TLS registry; the
    # openssl CLI wants its own name for exactly one of them
    # (`secp256r1` is `prime256v1` there, and `genpkey` rejects the IANA
    # spelling outright rather than aliasing it). Every other curve
    # below is spelled identically by both, and is listed anyway so an
    # unsupported name fails with the Ansible module's own error text
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

    # Live-verified against ansible-core 2.19.11 (community.crypto
    # 3.1.1) via `{{ r | to_json }}` dumps, identical on changed,
    # unchanged, check-mode and state=absent runs. Variant positions
    # confirmed live too: curve sits after fingerprint (before diff),
    # privatekey after curve, backup_file after changed, warnings last.
    # `diff` is present in Ansible's every success result; krikri emits no
    # diff here, so the key is simply skipped by the reorder.
    SUCCESS_KEY_ORDER = %w[
      type size fingerprint curve privatekey diff filename changed
      backup_file failed warnings
    ]

    def execute : PluginResult
      path = @params["path"]?
      return failure("state is present but all of the following are missing: path") unless path

      path = expand_tilde(path)
      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)

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
      # change, exactly as the Ansible module reports it (it runs the file
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

    private def write_key(regen : Bool, convert : Bool, path : String, type : String, size : Int32, # ameba:disable Metrics/CyclomaticComplexity
                          curve : String?, passphrase : String?, cipher : String, format : String) : PluginResult
      return result(true, path, type, size, curve, nil) if true?(@params["_ansible_check_mode"]?)

      if regen
        # The cryptography library's own generate-time ValueErrors - Ansible's
        # module body doesn't catch them, so the msg carries the full
        # unhandled-exception chain (live-verified vs 2.19.11 with
        # size: 96).
        if detail = key_size_error(type, size)
          return unhandled_error(detail)
        end
      end
      # Real serializes AFTER generating; a non-"auto" cipher with a
      # passphrase fails there with this exact fail_json msg (bare, no
      # chain prefix).
      if (passphrase && !passphrase.empty?) && !cipher.empty? && cipher != "auto"
        return failure("Cryptography backend can only use \"auto\" for cipher option.")
      end

      backup_file = backup(path)
      error = regen ? generate(path, type, size, curve, passphrase, format) : convert_format(path, type, passphrase, format)
      # module.warn rides in the result, so the deprecated-curve warning
      # Ansible emits at generate_private_key time shows on the failure
      # result too (fail_json includes the collected warnings).
      if warning = curve_warning(regen ? curve : nil, type)
        return attach_warning(failure(error), warning) if error
        return attach_warning(result(true, path, type, size, curve, backup_file), warning)
      end
      return failure(error) if error

      apply_attrs(path, default_mode: true)
      result(true, path, type, size, curve, backup_file)
    end

    # The Ansible module's curve table marks these deprecated and warns at
    # generation time (PrivateKeyBackend.generate_private_key): "Elliptic
    # curves of type X should not be used for new keys!" - only when a
    # key is actually generated, never on an idempotent no-change run or
    # a format conversion.
    DEPRECATED_CURVES = %w[
      secp192r1 sect163k1 sect163r2 sect233k1 sect233r1 sect283k1
      sect283r1 sect409k1 sect409r1 sect571k1 sect571r1
      brainpoolP256r1 brainpoolP384r1 brainpoolP512r1
    ]

    private def curve_warning(curve : String?, type : String) : String?
      return nil unless type == "ECC" && curve && DEPRECATED_CURVES.includes?(curve)
      "Elliptic curves of type #{curve} should not be used for new keys!"
    end

    private def attach_warning(res : PluginResult, warning : String) : PluginResult
      res.extra["warnings"] = JSON.parse([warning].to_json)
      res
    end

    # The "unhandled module exception" result shape Ansible 2.19 produces:
    # the fatal msg carries the full "Task failed: Module failed: <exc>"
    # chain while the error block shows the bare exception text.
    private def unhandled_error(detail : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
    end

    # cryptography's generate_private_key size guards (its own ValueError
    # texts - RSA and DSA differ).
    private def key_size_error(type : String, size : Int32) : String?
      case type
      when "RSA"
        return "key_size must be at least 1024-bits." if size < 1024
      when "DSA"
        return "Key size must be 1024, 2048, 3072, or 4096 bits." unless [1024, 2048, 3072, 4096].includes?(size)
      end
      nil
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

      res = PluginResult.new(changed: changed, failed: false, msg: "", key_order: SUCCESS_KEY_ORDER)
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

      res = PluginResult.new(changed: exists, failed: false, msg: "", key_order: SUCCESS_KEY_ORDER)
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
    # an unencrypted key is a mismatch to the Ansible module too (Python's
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
      read_key(path, passphrase) != nil
    end

    private def read_key(path : String, passphrase : String?) : Pointer(Void)?
      Pkey.load(File.read(path), passphrase)
    rescue
      nil
    end

    private def size_and_type_match?(path : String, passphrase : String?, type : String,
                                     size : Int32, curve : String?) : Bool
      # A `format: raw` key on disk is bare key material - no PEM, no
      # DER, nothing that can be parsed back and nothing that records its
      # own type. All that can be checked is that its length is the one
      # this type produces, which is what the Ansible module effectively
      # does too (it loads the bytes AS the configured type).
      if raw_file?(path)
        return false unless EDWARDS_TYPES.includes?(type)
        return File.size(path) == raw_size(type)
      end

      pkey = read_key(path, passphrase)
      return false unless pkey
      info = Pkey.info(pkey)
      Pkey.free_pkey(pkey)
      case type
      when "RSA"
        info.base_nid == NID_RSA && info.bits == size
      when "DSA"
        info.base_nid == NID_DSA && info.bits == size
      when "ECC"
        openssl_curve = CURVE_ALIASES[curve]? || curve
        info.base_nid == NID_EC && info.curve_sn == openssl_curve
      when "Ed25519", "Ed448", "X25519", "X448"
        info.base_nid == TYPE_NIDS[type]?
      else
        false
      end
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

    # The "auto" cipher - the only one the Ansible module's cryptography
    # backend accepts, and the only one this native path ever applies -
    # is AES-256-CBC, already handled inside the libcrypto helper.

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
                         passphrase : String?, format : String) : String?
      pkey = Pkey.generate(type, size, curve_nid(curve))
      unless pkey
        return "value of type must be one of: DSA, ECC, Ed25519, Ed448, RSA, X25519, X448, got: #{type}" unless TYPE_NIDS[type]?
        return "key generation failed for type #{type}"
      end
      tmp = secure_tempfile(path, "privatekey-out")
      begin
        if error = write_serialized(pkey, tmp, type, passphrase, effective_format(type, format))
          return error
        end
        File.rename(tmp, path)
        nil
      ensure
        File.delete(tmp) if File.exists?(tmp)
        Pkey.free_pkey(pkey)
      end
    end

    private def curve_nid(curve : String?) : Int32
      return 0 unless curve
      openssl_curve = CURVE_ALIASES[curve]? || curve
      LibCrypto.obj_sn2nid(openssl_curve.to_unsafe)
    end

    # Writes *pkey* out to *dest* (a pre-created 0600 temporary next to
    # the destination) in the requested format, encrypting when a
    # passphrase is set.
    private def write_serialized(pkey : Pointer(Void), dest : String, type : String,
                                 passphrase : String?, format : String) : String?
      if format == "raw"
        return write_raw(pkey, dest, type)
      end

      pem = Pkey.serialize_pem(pkey, type, format, passphrase)
      return "key serialization failed" unless pem
      File.write(dest, pem)
      nil
    end

    # `format: raw` for the Edwards/montgomery types: the bare key
    # bytes, no PEM, no DER wrapper. They are the tail of the PKCS#8
    # DER encoding (a fixed-size header followed by the key itself), so
    # slicing that off reproduces `private_bytes(Encoding.Raw)` exactly
    # - verified byte-for-byte against the Ansible module's output.
    private def write_raw(pkey : Pointer(Void), dest : String, type : String) : String?
      return "format: raw is only supported for Ed25519, Ed448, X25519 and X448 keys" unless EDWARDS_TYPES.includes?(type)

      der = Pkey.pkcs8_der(pkey)
      return "key serialization failed" unless der
      size = raw_size(type)
      return "unexpected DER length #{der.size} for a #{type} key" if der.size < size
      File.write(dest, der[der.size - size, size])
      nil
    end

    private def convert_format(path : String, type : String, passphrase : String?,
                               format : String) : String?
      pkey = read_key(path, passphrase)
      return "Unable to read the key. The key is protected with a another passphrase / no passphrase or broken." unless pkey
      tmp = secure_tempfile(path, "privatekey-out")
      begin
        if error = write_serialized(pkey, tmp, type, passphrase, effective_format(type, format))
          return error
        end
        File.rename(tmp, path)
        nil
      ensure
        File.delete(tmp) if File.exists?(tmp)
        Pkey.free_pkey(pkey)
      end
    end

    # --- reporting ----------------------------------------------------

    # The Ansible module fingerprints the PUBLIC key's DER
    # (SubjectPublicKeyInfo), colon-separated lowercase hex, over every
    # hashlib algorithm it can - verified: sha256 here equals the
    # module's own `fingerprint.sha256` for the same key.
    private def fingerprints(path : String) : Hash(String, JSON::Any)?
      return nil unless File.exists?(path)
      # No public key can be derived from bare raw bytes without knowing
      # the algorithm; the Ansible module returns no fingerprint here either.
      return nil if raw_file?(path)

      loaded = read_key(path, @params["passphrase"]?)
      return nil unless loaded
      der = Pkey.public_der(loaded)
      Pkey.free_pkey(loaded)
      return nil unless der

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
      # (verified against the Ansible module's own shake_128/shake_256).
      # Silently skipped where the CLI is absent or too old to know
      # -xoflen rather than failing the task over a reporting field.
      {"shake_128" => "shake128", "shake_256" => "shake256"}.each do |name, algorithm|
        if hex = shake_digest(der, algorithm)
          result[name] = JSON::Any.new(hex)
        end
      end

      result.empty? ? nil : result
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

    # Ansible's backup_local: "<path>.<pid>.<YYYY-MM-DD@HH:MM:SS>~"
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
