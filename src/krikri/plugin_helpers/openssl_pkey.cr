# Native libcrypto bindings for private-key generation, serialization and
# inspection - the same library the `openssl` CLI would shell out to, used
# directly so key generation works on hosts without the CLI binary (the
# plugin binaries already link libcrypto through Crystal's OpenSSL
# bindings, so nothing new is pulled in on the target).
#
# One shared declaration block for every plugin that needs it: two `fun`s
# for the same C symbol clash in the fat plugin binary (the clash keys on
# the C symbol name), so nothing here may re-declare a symbol another
# plugin or Crystal's own `LibCrypto` already declares - symbols Crystal's
# stdlib covers (BIO_new/BIO_free/BIO_ctrl, OBJ_sn2nid/OBJ_nid2sn,
# EC_KEY_free, ...) are used from there. Symbols other plugins already
# declare (EVP_PKEY_free, BIO_s_mem) keep the exact same alias and
# signature those declarations use.
require "openssl"

module Krikri
  module PluginHelpers
    @[Link("crypto")]
    lib LibCryptoPkey
      fun bio_s_mem = BIO_s_mem : LibCrypto::BioMethod*
      fun bio_new_mem_buf = BIO_new_mem_buf(UInt8*, Int32) : LibCrypto::Bio*
      fun pem_read_bio_private_key = PEM_read_bio_PrivateKey(LibCrypto::Bio*, Void**, Void*, Void*) : Void*
      fun pem_write_bio_pkcs8_private_key = PEM_write_bio_PKCS8PrivateKey(LibCrypto::Bio*, Void*, Void*, UInt8*, Int32, Void*, Void*) : Int32
      fun pem_write_bio_rsa_private_key = PEM_write_bio_RSAPrivateKey(LibCrypto::Bio*, Void*, Void*, UInt8*, Int32, Void*, Void*) : Int32
      fun pem_write_bio_dsa_private_key = PEM_write_bio_DSAPrivateKey(LibCrypto::Bio*, Void*, Void*, UInt8*, Int32, Void*, Void*) : Int32
      fun pem_write_bio_ec_private_key = PEM_write_bio_ECPrivateKey(LibCrypto::Bio*, Void*, Void*, UInt8*, Int32, Void*, Void*) : Int32
      fun evp_pkey_ctx_new_id = EVP_PKEY_CTX_new_id(Int32, Void*) : Void*
      fun evp_pkey_ctx_free = EVP_PKEY_CTX_free(Void*) : Void
      fun evp_pkey_keygen_init = EVP_PKEY_keygen_init(Void*) : Int32
      fun evp_pkey_keygen = EVP_PKEY_keygen(Void*, Void**) : Int32
      fun evp_pkey_ctx_set_rsa_keygen_bits = EVP_PKEY_CTX_set_rsa_keygen_bits(Void*, Int32) : Int32
      fun evp_pkey_ctx_set_dsa_paramgen_bits = EVP_PKEY_CTX_set_dsa_paramgen_bits(Void*, Int32) : Int32
      fun evp_pkey_ctx_set_ec_paramgen_curve_nid = EVP_PKEY_CTX_set_ec_paramgen_curve_nid(Void*, Int32) : Int32
      fun evp_pkey_get_base_id = EVP_PKEY_get_base_id(Void*) : Int32
      fun evp_pkey_get_bits = EVP_PKEY_get_bits(Void*) : Int32
      fun evp_pkey_get1_rsa = EVP_PKEY_get1_RSA(Void*) : Void*
      fun evp_pkey_get1_dsa = EVP_PKEY_get1_DSA(Void*) : Void*
      fun evp_pkey_get1_ec_key = EVP_PKEY_get1_EC_KEY(Void*) : Void*
      fun evp_pkey_free = EVP_PKEY_free(Void*) : Void
      fun rsa_free = RSA_free(Void*) : Void
      fun dsa_free = DSA_free(Void*) : Void
      fun ec_key_get0_group = EC_KEY_get0_group(Void*) : Void*
      fun ec_group_get_curve_name = EC_GROUP_get_curve_name(Void*) : Int32
      fun i2d_pubkey = i2d_PUBKEY(Void*, UInt8**) : Int32
      fun i2d_pkcs8_private_key_bio = i2d_PKCS8PrivateKey_bio(LibCrypto::Bio*, Void*, Void*, UInt8*, Int32, Void*, Void*) : Int32
      fun evp_aes_256_cbc = EVP_aes_256_cbc : Void*
      fun pem_read_bio_pubkey = PEM_read_bio_PUBKEY(LibCrypto::Bio*, Void**, Void*, Void*) : Void*
      fun pem_write_bio_pubkey = PEM_write_bio_PUBKEY(LibCrypto::Bio*, Void*) : Int32
      fun err_clear_error = ERR_clear_error : Void
      fun err_print_errors = ERR_print_errors(LibCrypto::Bio*) : Void
      fun err_lib_error_string = ERR_lib_error_string(Int32) : LibC::Char*
      fun err_func_error_string = ERR_func_error_string(UInt64) : LibC::Char*
      fun err_reason_error_string = ERR_reason_error_string(UInt64) : LibC::Char*
    end

    # The operations openssl_privatekey (and any future key-material
    # plugin) needs, expressed against EVP_PKEY handles:
    #
    #   generate        - EVP_PKEY keygen for RSA/DSA/ECC/Ed25519/Ed448/
    #                     X25519/X448 (DSA gets its parameters generated
    #                     in the same keygen pass, as `openssl genpkey`
    #                     does)
    #   serialize_pem   - PEM output: PKCS#8, traditional PKCS#1
    #                     (RSA/DSA/EC), or PKCS#8 for the Edwards types
    #                     that have no traditional encoding; optionally
    #                     encrypted with AES-256-CBC (the "auto" cipher,
    #                     which is the only cipher the real module's
    #                     cryptography backend accepts)
    #   pkcs8_der       - unencrypted DER PrivateKeyInfo (the source of
    #                     `format: raw`'s bare key bytes)
    #   load            - parse PEM/DER key material back into a handle,
    #                     with the given passphrase (nil on any failure -
    #                     wrong passphrase, not a key at all, ...)
    #   info            - key type NID, size in bits and (for EC keys) the
    #                     curve's OpenSSL short name
    #   public_der      - SubjectPublicKeyInfo DER, the fingerprint input
    module Pkey
      NID_RSA    = 6    # NID_rsaEncryption
      NID_DSA    = 116  # NID_dsa
      NID_EC     = 408  # NID_X9_62_id_ecPublicKey
      NID_X25519 = 1034
      NID_X448   = 1035
      NID_ED25519 = 1087
      NID_ED448   = 1088

      BIO_CTRL_INFO = 3

      TYPE_NIDS = {
        "RSA"     => NID_RSA,
        "DSA"     => NID_DSA,
        "ECC"     => NID_EC,
        "Ed25519" => NID_ED25519,
        "Ed448"   => NID_ED448,
        "X25519"  => NID_X25519,
        "X448"    => NID_X448,
      }

      extend self

      # EVP_PKEY* the caller owns (free_pkey) or nil on any failure.
      def generate(type : String, size : Int32, curve_nid : Int32) : Void*?
        nid = TYPE_NIDS[type]?
        return nil unless nid

        ctx = LibCryptoPkey.evp_pkey_ctx_new_id(nid, nil)
        return nil if ctx.null?
        begin
          return nil if LibCryptoPkey.evp_pkey_keygen_init(ctx) != 1
          case type
          when "RSA"
            return nil if LibCryptoPkey.evp_pkey_ctx_set_rsa_keygen_bits(ctx, size) != 1
          when "DSA"
            return nil if LibCryptoPkey.evp_pkey_ctx_set_dsa_paramgen_bits(ctx, size) != 1
          when "ECC"
            return nil if curve_nid == 0
            return nil if LibCryptoPkey.evp_pkey_ctx_set_ec_paramgen_curve_nid(ctx, curve_nid) != 1
          end
          pkey = Pointer(Void).null
          return nil if LibCryptoPkey.evp_pkey_keygen(ctx, pointerof(pkey)) != 1
          pkey
        ensure
          LibCryptoPkey.evp_pkey_ctx_free(ctx) unless ctx.null?
        end
      end

      def free_pkey(pkey : Void*) : Nil
        LibCryptoPkey.evp_pkey_free(pkey)
      end

      # PEM bytes for *pkey*, or nil. format is "pkcs8" or "pkcs1" (raw is
      # the caller's job - it needs the DER, not a PEM wrapper).
      def serialize_pem(pkey : Void*, type : String, format : String, passphrase : String?) : Bytes?
        bio = LibCrypto.BIO_new(LibCryptoPkey.bio_s_mem)
        return nil if bio.null?
        begin
          rc = write_pem(bio, pkey, type, format, passphrase)
          return nil unless rc == 1
          bio_contents(bio)
        ensure
          LibCrypto.BIO_free(bio)
        end
      end

      private def write_pem(bio : LibCrypto::Bio*, pkey : Void*, type : String, format : String, passphrase : String?) : Int32
        cipher, kstr, klen = encryption_args(passphrase)
        if format == "pkcs8"
          return LibCryptoPkey.pem_write_bio_pkcs8_private_key(bio, pkey, cipher, kstr, klen, nil, nil)
        end

        # pkcs1: the traditional per-algorithm serialization. The Edwards
        # and Montgomery types have none - PKCS#8 is their only PEM form,
        # so an explicit `format: pkcs1` for them still writes PKCS#8.
        case type
        when "RSA"
          rsa = LibCryptoPkey.evp_pkey_get1_rsa(pkey)
          return 0 if rsa.null?
          rc = LibCryptoPkey.pem_write_bio_rsa_private_key(bio, rsa, cipher, kstr, klen, nil, nil)
          LibCryptoPkey.rsa_free(rsa)
          rc
        when "DSA"
          dsa = LibCryptoPkey.evp_pkey_get1_dsa(pkey)
          return 0 if dsa.null?
          rc = LibCryptoPkey.pem_write_bio_dsa_private_key(bio, dsa, cipher, kstr, klen, nil, nil)
          LibCryptoPkey.dsa_free(dsa)
          rc
        when "ECC"
          ec = LibCryptoPkey.evp_pkey_get1_ec_key(pkey)
          return 0 if ec.null?
          rc = LibCryptoPkey.pem_write_bio_ec_private_key(bio, ec, cipher, kstr, klen, nil, nil)
          LibCrypto.ec_key_free(ec)
          rc
        else
          LibCryptoPkey.pem_write_bio_pkcs8_private_key(bio, pkey, cipher, kstr, klen, nil, nil)
        end
      end

      # cipher "auto" - the only encryption the real module's cryptography
      # backend ever applies - is AES-256-CBC.
      private def encryption_args(passphrase : String?) : {Void*, UInt8*, Int32}
        if passphrase && !passphrase.empty?
          {LibCryptoPkey.evp_aes_256_cbc, passphrase.to_slice.to_unsafe, passphrase.bytesize}
        else
          {Pointer(Void).null, Pointer(UInt8).null, 0}
        end
      end

      # Unencrypted DER PrivateKeyInfo - `format: raw` slices the bare key
      # bytes off its tail (the Edwards/montgomery key is the last field).
      def pkcs8_der(pkey : Void*) : Bytes?
        bio = LibCrypto.BIO_new(LibCryptoPkey.bio_s_mem)
        return nil if bio.null?
        begin
          return nil unless LibCryptoPkey.i2d_pkcs8_private_key_bio(bio, pkey, nil, nil, 0, nil, nil) == 1
          bio_contents(bio)
        ensure
          LibCrypto.BIO_free(bio)
        end
      end

      # Parses PEM key material back into an EVP_PKEY handle the caller
      # owns, decrypting with *passphrase* when the key is encrypted. nil
      # on any failure (wrong passphrase, not key material, truncated PEM).
      def load(data : Bytes | String, passphrase : String?) : Void*?
        slice = data.is_a?(String) ? data.to_slice : data
        bio = LibCryptoPkey.bio_new_mem_buf(slice.to_unsafe, slice.size)
        return nil if bio.null?
        begin
          pass_ptr = passphrase && !passphrase.empty? ? passphrase.to_slice.to_unsafe.as(Void*) : Pointer(Void).null
          pkey = LibCryptoPkey.pem_read_bio_private_key(bio, nil, nil, pass_ptr)
          pkey.null? ? nil : pkey
        ensure
          LibCrypto.BIO_free(bio)
        end
      end

      # The failure message the real module's load_privatekey produces for
      # an unparsable key: Python's `cryptography` raises ValueError whose
      # str() is the "(message, [OpenSSLError...])" tuple repr, and the
      # module prefixes it. The message itself is `cryptography`'s fixed
      # text; the OpenSSLError entries come from libcrypto's error queue
      # (same codes real reports, since both link the target's libcrypto).
      #
      #   *passphrase_problem* is the module's TypeError branch instead -
      # "Wrong or empty passphrase provided for private key" - used when
      # the password/password-less attempt mismatch is the failure itself.
      record LoadFailure, passphrase_problem : Bool, message : String

      private COULD_NOT_DESERIALIZE = "Could not deserialize key data. The data may be in an incorrect format, the provided password may be incorrect, it may be encrypted with an unsupported algorithm, or it may be an unsupported key type (e.g. EC curves with explicit parameters)."

      # cryptography-semantics private-key load: on failure the returned
      # LoadFailure.message is byte-for-byte what the real module puts in
      # fail_json (verified against community.crypto 3.1.1 + the libcrypto
      # the target ships). On success the caller owns the returned
      # EVP_PKEY (free_pkey).
      def load_checked(data : Bytes | String, passphrase : String?) : {Void*?, LoadFailure?}
        # The encryption-marker check comes FIRST (as `cryptography`'s
        # PEM handling does): a nil-password PEM_read_bio_PrivateKey on
        # encrypted material would fall into libcrypto's interactive
        # passphrase prompt instead of failing cleanly.
        if passphrase
          LibCryptoPkey.err_clear_error
          pkey = read(data, passphrase)
          encrypted = encrypted_marker?(data)
          unless pkey.null?
            # Loaded WITH a password: an unencrypted key loads without one
            # too, and that mismatch is the real module's TypeError branch
            # ("Password was given but private key is not encrypted.").
            return {pkey, nil} if encrypted
            LibCryptoPkey.err_clear_error
            plain = read(data, nil)
            unless plain.null?
              free_pkey(plain)
              return {nil, LoadFailure.new(true, "Wrong or empty passphrase provided for private key")}
            end
            return {pkey, nil}
          end
          failures = drain_error_queue

          unless encrypted
            LibCryptoPkey.err_clear_error
            plain = read(data, nil)
            unless plain.null?
              free_pkey(plain)
              return {nil, LoadFailure.new(true, "Wrong or empty passphrase provided for private key")}
            end
          end
          return {nil, LoadFailure.new(false, unparsable_message(failures))}
        end

        if encrypted_marker?(data)
          return {nil, LoadFailure.new(true, "Wrong or empty passphrase provided for private key")}
        end

        LibCryptoPkey.err_clear_error
        pkey = read(data, nil)
        return {pkey, nil} unless pkey.null?
        failures = drain_error_queue
        {nil, LoadFailure.new(false, unparsable_message(failures))}
      end

      # Unlike #load, an empty-string passphrase is a GIVEN password (the
      # real module hands `cryptography` b"") - only nil means none.
      private def read(data : Bytes | String, passphrase : String?) : Void*?
        slice = data.is_a?(String) ? data.to_slice : data
        bio = LibCryptoPkey.bio_new_mem_buf(slice.to_unsafe, slice.size)
        return Pointer(Void).null if bio.null?
        begin
          pass_ptr = passphrase ? passphrase.to_slice.to_unsafe.as(Void*) : Pointer(Void).null
          pkey = LibCryptoPkey.pem_read_bio_private_key(bio, nil, nil, pass_ptr)
          pkey.null? ? Pointer(Void).null : pkey
        ensure
          LibCrypto.BIO_free(bio)
        end
      end

      private def unparsable_message(failures : Array(String)) : String
        "Wrong passphrase provided for private key, or private key cannot be parsed: " \
        "('#{COULD_NOT_DESERIALIZE}', [#{failures.join(", ")}])"
      end

      # The queue entries as `cryptography`'s OpenSSLError reprs. lib and
      # reason use OpenSSL 3's ERR_GET_LIB/ERR_GET_REASON masks.
      private def drain_error_queue : Array(String)
        entries = [] of String
        loop do
          code = LibCrypto.err_get_error
          break if code.zero?
          lib_n = (code >> 23) & 0x3FF
          reason = code & 0x7FFFFF
          reason_text = LibCryptoPkey.err_reason_error_string(code)
          text = reason_text.null? ? "None" : String.new(reason_text)
          entries << "<OpenSSLError(code=#{code}, lib=#{lib_n}, reason=#{reason}, reason_text=#{text})>"
        end
        entries
      end

      private def encrypted_marker?(data : Bytes | String) : Bool
        text = data.is_a?(String) ? data : String.new(data, invalid: :skip)
        text.includes?("ENCRYPTED PRIVATE KEY") || text.includes?("DEK-Info:") ||
          text.includes?("Proc-Type: 4,ENCRYPTED")
      end

      # SubjectPublicKeyInfo PEM of *pkey*'s public half - the bytes the
      # real module writes for `format: PEM`.
      def public_pem(pkey : Void*) : Bytes?
        bio = LibCrypto.BIO_new(LibCryptoPkey.bio_s_mem)
        return nil if bio.null?
        begin
          return nil unless LibCryptoPkey.pem_write_bio_pubkey(bio, pkey) == 1
          bio_contents(bio)
        ensure
          LibCrypto.BIO_free(bio)
        end
      end

      # Parses PEM public key material (SubjectPublicKeyInfo) back into an
      # EVP_PKEY handle the caller owns; nil on any failure.
      def load_public(data : Bytes | String) : Void*?
        slice = data.is_a?(String) ? data.to_slice : data
        bio = LibCryptoPkey.bio_new_mem_buf(slice.to_unsafe, slice.size)
        return nil if bio.null?
        begin
          pkey = LibCryptoPkey.pem_read_bio_pubkey(bio, nil, nil, nil)
          pkey.null? ? nil : pkey
        ensure
          LibCrypto.BIO_free(bio)
        end
      end

      record Info, base_nid : Int32, bits : Int32, curve_sn : String?

      def info(pkey : Void*) : Info
        base_nid = LibCryptoPkey.evp_pkey_get_base_id(pkey)
        bits = LibCryptoPkey.evp_pkey_get_bits(pkey)
        curve_sn = nil
        if base_nid == NID_EC
          ec = LibCryptoPkey.evp_pkey_get1_ec_key(pkey)
          unless ec.null?
            begin
              group = LibCryptoPkey.ec_key_get0_group(ec)
              unless group.null?
                nid = LibCryptoPkey.ec_group_get_curve_name(group)
                if nid != 0
                  sn = LibCrypto.obj_nid2sn(nid)
                  curve_sn = sn.null? ? nil : String.new(sn)
                end
              end
            ensure
              LibCrypto.ec_key_free(ec)
            end
          end
        end
        Info.new(base_nid, bits, curve_sn)
      end

      # SubjectPublicKeyInfo DER - the input the real module hashes for
      # its `fingerprint` result.
      def public_der(pkey : Void*) : Bytes?
        len = LibCryptoPkey.i2d_pubkey(pkey, nil)
        return nil if len <= 0
        buf = Pointer(UInt8).malloc(len)
        cursor = buf
        rc = LibCryptoPkey.i2d_pubkey(pkey, pointerof(cursor))
        return nil unless rc == len
        Bytes.new(len) { |i| buf[i] }
      end

      private def bio_contents(bio : LibCrypto::Bio*) : Bytes?
        ptr = Pointer(UInt8).null
        len = LibCrypto.BIO_ctrl(bio, BIO_CTRL_INFO, 0, pointerof(ptr))
        return nil if len <= 0 || ptr.null?
        Bytes.new(len.to_i32) { |i| ptr[i] }
      end
    end
  end
end
