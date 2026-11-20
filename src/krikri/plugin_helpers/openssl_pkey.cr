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
    #                     which is the only cipher the Ansible module's
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
      NID_RSA     =    6 # NID_rsaEncryption
      NID_DSA     =  116 # NID_dsa
      NID_EC      =  408 # NID_X9_62_id_ecPublicKey
      NID_X25519  = 1034
      NID_X448    = 1035
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
      def generate(type : String, size : Int32, curve_nid : Int32) : Void*? # ameba:disable Metrics/CyclomaticComplexity
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

      # cipher "auto" - the only encryption the Ansible module's cryptography
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

      # The failure message the Ansible module's load_privatekey produces for
      # an unparsable key: `support.py` prefixes whatever `cryptography`
      # raised. cryptography 50 - what the pinned ansible-core 2.21.6
      # reference hosts install - parses the PEM framing in Rust before
      # OpenSSL sees any bytes, so its ValueError text is no longer the old
      # "(message, [OpenSSLError...])" tuple repr. Private keys that do reach
      # OpenSSL keep that older text (#unparsable_message).
      #
      #   *passphrase_problem* is the module's TypeError branch instead -
      # "Wrong or empty passphrase provided for private key" - used when
      # the password/password-less attempt mismatch is the failure itself.
      record LoadFailure, passphrase_problem : Bool, message : String

      # A PEM section; *pem* is its raw text so libcrypto can parse just that
      # block (cryptography hands it the decoded block contents, never the
      # surrounding file).
      private record PemSection, tag : String, headers : String, pem : String

      private PRIVATE_KEY_TAGS = ["PRIVATE KEY", "ENCRYPTED PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY", "DSA PRIVATE KEY"]

      # cryptography 50's `From<pem::PemError>` wrapper: the Rust `pem`
      # crate's error Debug repr is appended to this fixed text.
      private UNABLE_TO_LOAD_PEM = "Unable to load PEM file. See https://cryptography.io/en/latest/faq/#why-can-t-i-import-my-pem-file for more details."

      # `x509::find_in_pem`'s no-match message: the PEM parses but holds no
      # block with a private-key tag.
      private NO_PRIVATE_KEY_DELIMITERS = "Valid PEM but no BEGIN/END delimiters for a private key found. Are you sure this is a private key?"

      private INCORRECT_PASSWORD = "Incorrect password, could not decrypt key"

      private COULD_NOT_DESERIALIZE = "Could not deserialize key data. The data may be in an incorrect format, the provided password may be incorrect, it may be encrypted with an unsupported algorithm, or it may be an unsupported key type (e.g. EC curves with explicit parameters)."

      # cryptography-semantics private-key load: on failure the returned
      # LoadFailure.message is byte-for-byte what the Ansible module puts in
      # fail_json (verified against community.crypto 3.1.1 + cryptography 50
      # on the ansible-core 2.21.6 reference hosts). On success the caller
      # owns the returned EVP_PKEY (free_pkey).
      def load_checked(data : Bytes | String, passphrase : String?) : {Void*?, LoadFailure?}
        text = data.is_a?(String) ? data : String.new(data, invalid: :skip)
        sections, scan_error = pem_sections(text)
        return {nil, unparsable_key_failure("#{UNABLE_TO_LOAD_PEM} #{scan_error}")} if scan_error
        return {nil, unparsable_key_failure("#{UNABLE_TO_LOAD_PEM} MalformedFraming")} if sections.empty?

        section = sections.find { |candidate| PRIVATE_KEY_TAGS.includes?(candidate.tag) }
        return {nil, unparsable_key_failure(NO_PRIVATE_KEY_DELIMITERS)} unless section

        # Deciding encryption from the framing (not by trying libcrypto both
        # ways) is what cryptography does: a password on an unencrypted key,
        # or no password on an encrypted one, is its TypeError branch before
        # any decryption is attempted.
        encrypted = section.tag == "ENCRYPTED PRIVATE KEY" || legacy_encrypted?(section)
        if encrypted
          return {nil, wrong_passphrase_failure} unless passphrase && !passphrase.empty?

          LibCryptoPkey.err_clear_error
          pkey = read(section.pem, passphrase)
          return {pkey, nil} unless pkey.null?
          drain_error_queue
          return {nil, unparsable_key_failure(INCORRECT_PASSWORD)}
        end

        return {nil, wrong_passphrase_failure} if passphrase

        LibCryptoPkey.err_clear_error
        pkey = read(section.pem, nil)
        return {pkey, nil} unless pkey.null?
        failures = drain_error_queue
        {nil, LoadFailure.new(false, unparsable_message(failures))}
      end

      # Unlike #load, an empty-string passphrase is a GIVEN password (the
      # Ansible module hands `cryptography` b"") - only nil means none.
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

      private def unparsable_key_failure(error : String) : LoadFailure
        LoadFailure.new(false, "Wrong passphrase provided for private key, or private key cannot be parsed: #{error}")
      end

      private def wrong_passphrase_failure : LoadFailure
        LoadFailure.new(true, "Wrong or empty passphrase provided for private key")
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

      # Legacy PEM encryption (`openssl rsa -aes256` style) is identified by
      # the Proc-Type header, which is what cryptography's decrypt_pem reads.
      private def legacy_encrypted?(section : PemSection) : Bool
        section.headers.includes?("Proc-Type: 4,ENCRYPTED")
      end

      # PEM sections as the Rust `pem` crate 4.0.0 (linked by cryptography 50)
      # parses them: `-----BEGIN <tag>-----`, optional headers, data,
      # `-----END <tag>-----`. Returns the sections read so far plus the first
      # PemError Debug repr; like `parse_many`, one bad section aborts the scan.
      private def pem_sections(text : String) : {Array(PemSection), String?}
        sections = [] of PemSection
        offset = 0
        loop do
          begin_at = text.byte_index("-----BEGIN ", offset)
          break unless begin_at
          tag_start = begin_at + "-----BEGIN ".bytesize
          tag_end = text.byte_index("-----", tag_start)
          break unless tag_end
          tag = text.byte_slice(tag_start, tag_end - tag_start)
          payload_start = skip_pem_whitespace(text, tag_end + "-----".bytesize)
          end_marker = text.byte_index("-----END ", payload_start)
          break unless end_marker
          end_start = end_marker + "-----END ".bytesize
          end_tag_end = text.byte_index("-----", end_start)
          break unless end_tag_end
          end_tag = text.byte_slice(end_start, end_tag_end - end_start)

          return {sections, "MissingBeginTag"} if tag.empty?
          return {sections, "MissingEndTag"} if end_tag.empty?
          if tag != end_tag
            return {sections, "MismatchedTags(#{tag.inspect}, #{end_tag.inspect})"}
          end

          headers = pem_header_block(text.byte_slice(payload_start, end_marker - payload_start))
          pem = text.byte_slice(begin_at, end_tag_end + "-----".bytesize - begin_at)
          sections << PemSection.new(tag, headers, pem)
          offset = end_tag_end + "-----".bytesize
        end
        {sections, nil}
      end

      private def skip_pem_whitespace(text : String, offset : Int32) : Int32
        while offset < text.bytesize
          case text.byte_at(offset)
          when 0x20, 0x09, 0x0a, 0x0d
            offset += 1
          else
            return offset
          end
        end
        offset
      end

      # Headers are everything before the first blank line; the crate tries
      # the LF pair before the CRLF one.
      private def pem_header_block(payload : String) : String
        if index = payload.byte_index("\n\n")
          payload.byte_slice(0, index)
        elsif index = payload.byte_index("\r\n\r\n")
          payload.byte_slice(0, index)
        else
          ""
        end
      end

      # SubjectPublicKeyInfo PEM of *pkey*'s public half - the bytes the
      # Ansible module writes for `format: PEM`.
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

      # SubjectPublicKeyInfo DER - the input the Ansible module hashes for
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
