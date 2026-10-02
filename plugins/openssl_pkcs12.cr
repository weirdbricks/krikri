#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/pem_bundle"

module Krikri
  # Minimal libcrypto bindings for native PKCS#12 parsing (the parse
  # action's own primitive - the plugin binary already links libcrypto
  # through Crystal's OpenSSL bindings). X509_free/OPENSSL_sk_num/
  # OPENSSL_sk_value are already declared in Crystal's own LibCrypto
  # (reused from there - redeclaring them under a different Crystal
  # name is a "fun redefinition" error since the clash keys on the C
  # symbol name).
  @[Link("crypto")]
  lib LibCryptoPkcs12
    fun d2i_pkcs12_bio = d2i_PKCS12_bio(LibCrypto::Bio*, Void**) : Void*
    fun pkcs12_free = PKCS12_free(Void*) : Void
    fun pkcs12_parse = PKCS12_parse(Void*, UInt8*, Void**, Void**, Void**) : Int32
    fun pem_write_bio_private_key = PEM_write_bio_PrivateKey(LibCrypto::Bio*, Void*, Void*, UInt8*, Int32, Void*, Void*) : Int32
    fun pem_write_bio_x509 = PEM_write_bio_X509(LibCrypto::Bio*, Void*) : Int32
    fun evp_pkey_free = EVP_PKEY_free(Void*) : Void
    fun bio_new_file = BIO_new_file(UInt8*, UInt8*) : LibCrypto::Bio*
    fun bio_s_mem = BIO_s_mem : LibCrypto::BioMethod*
  end

  # openssl_pkcs12 plugin (community.crypto.openssl_pkcs12) - bundles a
  # private key and its certificate into a PKCS#12 archive (`action:
  # export`), and converts one back into a PEM bundle (`action: parse`).
  #
  # Export is what the corpus uses (robertdebock.openssl / buluma.openssl
  # both export a `.p12` next to the key and cert they just generated).
  # Parse requires `src:` (the archive to read) and writes the private
  # key followed by the certificates as PEM to `path:` - the real
  # module's parse is a converter, not an info-only read.
  #
  # Differentialed against the real module (community.crypto 3.1.1):
  #
  #   * the archive is written 0400 unless `mode:` says otherwise - the
  #     tightest default of any module in this family
  #   * `mode`, `filename` and `privatekey_path` are the returned keys
  #   * changing the friendly name, the key or the certificate rewrites
  #     the archive; an unchanged export is a no-op
  #
  # Idempotency reads the existing archive back with the same
  # passphrase and compares the key, the certificate and the friendly
  # name against the sources - a PKCS#12 file is salted, so two exports
  # of identical inputs never produce identical bytes and a file
  # comparison would rewrite it on every run.
  class OpensslPkcs12Plugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # The real module's argument_spec (declaration order) plus the
    # file-common args its add_file_common_args=True injects (the only
    # alias is attributes->attr; friendly_name's alias is on the module
    # key below).
    SPEC = {
      "action"                       => [] of String,
      "other_certificates"           => [] of String,
      "other_certificates_parse_all" => [] of String,
      "other_certificates_content"   => [] of String,
      "certificate_path"             => [] of String,
      "certificate_content"          => [] of String,
      "force"                        => [] of String,
      "friendly_name"                => ["name"],
      "encryption_level"             => [] of String,
      "iter_size"                    => [] of String,
      "maciter_size"                 => [] of String,
      "passphrase"                   => [] of String,
      "path"                         => [] of String,
      "privatekey_passphrase"        => [] of String,
      "privatekey_path"              => [] of String,
      "privatekey_content"           => [] of String,
      "state"                        => [] of String,
      "src"                          => [] of String,
      "backup"                       => [] of String,
      "return_content"               => [] of String,
      "select_crypto_backend"        => [] of String,
      "mode"                         => [] of String,
      "owner"                        => [] of String,
      "group"                        => [] of String,
      "seuser"                       => [] of String,
      "serole"                       => [] of String,
      "selevel"                      => [] of String,
      "setype"                       => [] of String,
      "attributes"                   => ["attr"],
      "unsafe_writes"                => [] of String,
    }

    def execute : PluginResult
      result = run_execute
      # Real's argument spec marks maciter_size removed in
      # community.crypto 4.0.0 - passing it emits a controller-side
      # deprecation warning alongside ANY result (including failures),
      # live-verified vs 2.19.11.
      if @params["maciter_size"]? && (deprecation = MACITER_DEPRECATION)
        marker = result.extra["_ansible_core_deprecations"]?
        list = marker.try(&.as_a?) || [] of JSON::Any
        list << JSON::Any.new(deprecation)
        result.extra["_ansible_core_deprecations"] = JSON::Any.new(list)
      end
      result
    end

    MACITER_DEPRECATION = "Param 'maciter_size' is deprecated. See the module docs for more information. This feature will be removed from collection 'community.crypto' version 4.0.0."

    private def run_execute : PluginResult
      if err = validate_arguments
        return err
      end

      # Real's backend constructor (select_backend runs BEFORE the
      # base_dir check and the state dispatch) eagerly reads every
      # provided file input - certificate, then private key, then the
      # other certificates - and a missing file surfaces as the
      # UNHANDLED OSError chain ("Task failed: Module failed: [Errno 2]
      # ..."), in every state and even in check mode (live-verified vs
      # 2.19.11 with state=absent).
      if (cert_path = @params["certificate_path"]?) && !File.exists?(expand_tilde(cert_path))
        return unhandled_error("[Errno 2] No such file or directory: '#{expand_tilde(cert_path)}'")
      end
      if (key_path = @params["privatekey_path"]?) && !File.exists?(expand_tilde(key_path))
        return unhandled_error("[Errno 2] No such file or directory: '#{expand_tilde(key_path)}'")
      end
      if @params["other_certificates"]? && !@params["other_certificates_content"]?
        other_certificates([] of String).each do |other|
          unless File.exists?(other)
            return unhandled_error("[Errno 2] No such file or directory: '#{other}'")
          end
        end
      end

      temp_files = [] of String
      begin
        path = expand_tilde(@params["path"])
        state = @params["state"]? || "present"
        check_mode = true?(@params["_ansible_check_mode"]?)
        action = @params["action"]? || "export"

        return remove(path, check_mode) if state == "absent"
        return execute_parse(path, check_mode) if action == "parse"
        execute_export(path, check_mode, temp_files)
      ensure
        temp_files.each { |file| File.delete(file) rescue nil }
      end
    end

    # The "unhandled module exception" result shape real 2.19 produces:
    # the fatal msg carries the full "Task failed: Module failed: <exc>"
    # chain while the error block shows the bare exception text.
    private def unhandled_error(detail : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
    end

    private def execute_parse(path : String, check_mode : Bool) : PluginResult
      src = @params["src"]?.try { |value| expand_tilde(value) }
      return failure("action is parse but all of the following are missing: src") unless src
      return failure("The PKCS#12 file #{src} does not exist") unless File.exists?(src)
      parse_action(path, src, check_mode)
    end

    private def execute_export(path : String, check_mode : Bool, temp_files : Array(String)) : PluginResult
      privatekey_path, certificate_path = resolve_key_material(temp_files)
      return failure("state is present but all of the following are missing: privatekey_path") unless privatekey_path
      return failure("The private key #{privatekey_path} does not exist") unless File.exists?(privatekey_path)
      if error = validate_rest(path, certificate_path)
        return error
      end

      # The real module serializes the archive through the
      # cryptography library: in check mode via the unconditional
      # dump() (a key/cert mismatch fails there before anything
      # else), on a write via generate_bytes() after its
      # friendly-name guard. An up-to-date archive without force
      # reaches neither.
      changed = content_changed(path, privatekey_path, certificate_path, temp_files)

      if error = key_cert_mismatch_error(privatekey_path, certificate_path, check_mode, changed)
        return error
      end

      if changed && check_mode
        return result(true, path, privatekey_path, nil)
      end

      if changed
        return export_changed(path, privatekey_path, certificate_path, temp_files)
      end

      attrs_changed = apply_attrs(path)
      result(attrs_changed, path, privatekey_path, nil)
    end

    # other_certificates_content entries are PEM texts - materialized to
    # temp files so `openssl pkcs12 -certfile` can consume them like the
    # path-based variant.
    private def resolve_key_material(temp_files : Array(String)) : {String?, String?}
      privatekey_path = @params["privatekey_path"]?.try { |value| expand_tilde(value) }
      certificate_path = @params["certificate_path"]?.try { |value| expand_tilde(value) }
      if privatekey_path.nil? && (content = @params["privatekey_content"]?)
        privatekey_path = write_temp_content(temp_files, content)
      end
      if certificate_path.nil? && (content = @params["certificate_content"]?)
        certificate_path = write_temp_content(temp_files, content)
      end
      {privatekey_path, certificate_path}
    end

    private def key_cert_mismatch_error(privatekey_path : String, certificate_path : String?, check_mode : Bool, changed : Bool) : PluginResult?
      return nil unless certificate_path && (check_mode || changed)
      return failure("Failed to create PKCS12 (does the key match the certificate?)") unless key_matches_cert?(privatekey_path, certificate_path)
      nil
    end

    private def export_changed(path : String, privatekey_path : String, certificate_path : String?, temp_files : Array(String)) : PluginResult
      # Module-level policy (community.crypto 3.x): an export write
      # always carries a friendly name.
      friendly_name = @params["friendly_name"]?
      return failure("Friendly_name is required") if friendly_name.nil? || friendly_name.empty?

      write_export(path, privatekey_path, certificate_path, temp_files)
    end

    private def content_changed(path : String, privatekey_path : String, certificate_path : String?, temp_files : Array(String)) : Bool
      true?(@params["force"]?) || !File.exists?(path) ||
        !matches?(path, privatekey_path, certificate_path, temp_files)
    end

    private def write_temp_content(temp_files : Array(String), content : String) : String
      file = File.tempname("pkcs12-content")
      File.write(file, content)
      temp_files << file
      file
    end

    private def other_certificates(temp_files : Array(String)) : Array(String)
      if (content_list = @params["other_certificates_content"]?) && !content_list.empty?
        entries = parse_list(content_list)
        return entries.map { |pem| write_temp_content(temp_files, pem) }
      end
      raw = @params["other_certificates"]?
      return [] of String if raw.nil? || raw.empty?
      parse_list(raw).map { |path| expand_tilde(path) }
    end

    # check_type_list semantics (a plain string is comma-split, no JSON
    # probing).
    private def parse_list(raw : String) : Array(String)
      case value = (JSON.parse(raw) rescue nil).try(&.raw)
      when Array
        value.map { |v| v.as_s? ? v.as_s : v.to_s }
      when String
        value.split(",").map(&.strip).reject(&.empty?)
      when Nil
        raw.split(",").map(&.strip).reject(&.empty?)
      else
        [value.to_s]
      end
    end

    private def validate_rest(path : String, certificate_path : String?) : PluginResult?
      if certificate_path && !File.exists?(certificate_path)
        return failure("The certificate #{certificate_path} does not exist")
      end

      base_dir = File.dirname(path)
      return failure("The directory #{base_dir} does not exist or the file is not a directory") unless Dir.exists?(base_dir)
      nil
    end

    private def key_matches_cert?(privatekey_path : String, certificate_path : String) : Bool
      key_pub = openssl_out(["pkey", "-in", privatekey_path, "-pubout"])
      cert_pub = openssl_out(["x509", "-in", certificate_path, "-pubkey", "-noout"])
      return false unless key_pub && cert_pub
      normalize_pem(key_pub) == normalize_pem(cert_pub)
    end

    private def openssl_out(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      status.success? ? stdout_io.to_s : nil
    end

    # action: parse - read the archive from `src`, write its private key
    # followed by its certificates as PEM to `path` (the real module's
    # parse is a converter, not an info-only read: it produces a file).
    # Idempotency compares the desired bundle against the file's current
    # content PEM-normalized (the real module compares its own
    # re-serialized PEM dump against the file's bytes, so both engines
    # settle on the same second-run "ok" and the same src-change rewrite).
    # Native PKCS#12 parse through libcrypto (real's own primitive, the
    # cryptography library's load_key_and_certificates): the private key
    # PEM (PKCS#8) followed by the certificate and every additional
    # certificate. Returns nil when the data cannot be deserialized -
    # real's exact fail_json text for that is "Could not deserialize
    # PKCS12 data".
    private def native_pkcs12_dump(path : String) : String?
      bio = LibCryptoPkcs12.bio_new_file(path, "rb")
      return nil unless bio
      begin
        p12 = LibCryptoPkcs12.d2i_pkcs12_bio(bio, Pointer(Pointer(Void)).null)
        return nil unless p12
        pkey = Pointer(Void).null
        cert = Pointer(Void).null
        ca = Pointer(Void).null
        rc = LibCryptoPkcs12.pkcs12_parse(p12, passphrase, pointerof(pkey), pointerof(cert), pointerof(ca))
        LibCryptoPkcs12.pkcs12_free(p12)
        return nil unless rc == 1

        String.build do |io|
          mem = LibCrypto.BIO_new(LibCryptoPkcs12.bio_s_mem)
          begin
            # The mem BIO keeps one contiguous buffer that never shrinks
            # (BIO_reset only rewinds the write pointer, it does not
            # truncate) - so each PEM writer's contribution is read as
            # "bytes beyond what earlier writers already produced",
            # tracked by offset.
            written = 0
            if pkey && !pkey.null?
              LibCryptoPkcs12.pem_write_bio_private_key(mem, pkey, nil, nil, 0, nil, nil)
              written = bio_append_since(mem, written, io)
            end
            if cert && !cert.null?
              LibCryptoPkcs12.pem_write_bio_x509(mem, cert)
              written = bio_append_since(mem, written, io)
            end
            if ca && !ca.null?
              (0...LibCrypto.sk_num(ca)).each do |idx|
                member = LibCrypto.sk_value(ca, idx)
                next if member.null?
                LibCryptoPkcs12.pem_write_bio_x509(mem, member)
                written = bio_append_since(mem, written, io)
              end
            end
          ensure
            LibCrypto.BIO_free(mem)
            LibCryptoPkcs12.evp_pkey_free(pkey) if pkey && !pkey.null?
            LibCrypto.x509_free(cert.as(LibCrypto::X509)) if cert && !cert.null?
            if ca && !ca.null?
              (0...LibCrypto.sk_num(ca)).each do |idx|
                member = LibCrypto.sk_value(ca, idx)
                LibCrypto.x509_free(member.as(LibCrypto::X509)) unless member.null?
              end
            end
          end
        end
      end
    end

    # BIO_CTRL_INFO (3) on a mem BIO returns the whole buffer: the data
    # pointer and its total length. The bytes beyond *written* are the
    # contribution of the PEM writer that just ran.
    private def bio_append_since(mem, written : Int32, io : IO) : Int32
      ptr = Pointer(UInt8).null
      total = LibCrypto.BIO_ctrl(mem, 3, 0, pointerof(ptr))
      return written unless total > written && ptr
      io << String.new(ptr + written, total - written)
      total.to_i32
    end

    private def parse_action(path : String, src : String, check_mode : Bool) : PluginResult
      base_dir = File.dirname(path)
      return failure("The directory #{base_dir} does not exist or the file is not a directory") unless Dir.exists?(base_dir)

      desired = key_first_bundle(native_pkcs12_dump(src))
      return failure("Could not deserialize PKCS12 data") unless desired

      changed = true?(@params["force"]?) || !File.exists?(path) ||
                normalize_pem(File.read(path)) != normalize_pem(desired)

      return result_parse(true, path, src) if changed && check_mode

      if changed && !check_mode
        backup_file = backup(path)
        File.write(path, desired)
        apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
        return result_parse(true, path, src, backup_file)
      end

      attrs_changed = parse_attrs(path)
      result_parse(attrs_changed, path, src)
    end

    private def key_first_bundle(dump : String?) : String?
      return nil unless dump
      PluginHelpers::PemBundle.key_first(dump)
    end

    private def result_parse(changed : Bool, path : String, src : String, backup_file : String? = nil) : PluginResult
      res = PluginResult.new(changed: changed, failed: false, msg: "")
      res.extra["filename"] = JSON::Any.new(path)
      res.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      res
    end

    # Unlike export (whose archive is 0400 by default), parse writes a
    # plain PEM bundle with the ordinary file-common default - no forced
    # mode unless one was asked for.
    private def parse_attrs(path : String) : Bool
      return false unless File.exists?(path)
      before = File.info(path).permissions.value
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      File.info(path).permissions.value != before
    rescue
      false
    end

    private def write_export(path : String, privatekey_path : String, certificate_path : String?, temp_files : Array(String)) : PluginResult
      backup_file = backup(path)
      if error = export(path, privatekey_path, certificate_path, temp_files)
        return failure(error)
      end
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]? || "0400")
      result(true, path, privatekey_path, backup_file)
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # Real AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required -> types (spec declaration order) -> choices -> required_if
    # -> mutually_exclusive -> unsupported (deferred last).
    private def validate_arguments : PluginResult?
      return missing_required_error(["path"]) unless @params["path"]?

      if error = check_numeric_and_bool_params
        return error
      end

      if error = check_choices
        return error
      end

      if (@params["action"]? || "export") == "parse" && !@params["src"]?
        return failure("action is parse but all of the following are missing: src")
      end

      if error = check_mutually_exclusive_pairs
        return error
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.openssl_pkcs12", unsupported, SPEC)
      end
      nil
    end

    private def check_numeric_and_bool_params : PluginResult?
      %w[iter_size maciter_size].each do |param|
        if raw = @params[param]?
          return int_type_error(param, raw) unless raw.to_i32?
        end
      end
      %w[other_certificates_parse_all force backup return_content unsafe_writes].each do |param|
        if raw = @params[param]?
          return bool_type_error(param, raw) unless bool_convertible?(raw)
        end
      end
      nil
    end

    private def check_choices : PluginResult?
      {"action"                => %w[export parse],
       "encryption_level"      => %w[auto compatibility2022],
       "state"                 => %w[absent present],
       "select_crypto_backend" => %w[auto cryptography]}.each do |param, allowed|
        if value = @params[param]?
          unless allowed.includes?(value)
            return choices_error(param, allowed, value)
          end
        end
      end
      nil
    end

    private def check_mutually_exclusive_pairs : PluginResult?
      [%w[privatekey_path privatekey_content], %w[certificate_path certificate_content],
       %w[other_certificates other_certificates_content]].each do |pair|
        if pair.all? { |param| @params[param]? }
          return failure("parameters are mutually exclusive: #{pair.join("|")}")
        end
      end
      nil
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

    private def passphrase : String
      @params["passphrase"]? || ""
    end

    private def export(path : String, privatekey_path : String, certificate_path : String?, temp_files : Array(String) = [] of String) : String?
      tmp = File.tempname("pkcs12", dir: File.dirname(path))
      begin
        File.write(tmp, "")
        File.chmod(tmp, 0o600)

        args = ["pkcs12", "-export", "-out", tmp, "-inkey", privatekey_path,
                "-passout", "pass:#{passphrase}"]
        args.concat(["-in", certificate_path]) if certificate_path
        if (name = @params["friendly_name"]?) && !name.empty?
          args.concat(["-name", name])
        end
        if (other = other_certificates(temp_files)) && !other.empty?
          other.each { |certificate| args.concat(["-certfile", certificate]) }
        end
        if (key_passphrase = @params["privatekey_passphrase"]?) && !key_passphrase.empty?
          args.concat(["-passin", "pass:#{key_passphrase}"])
        end

        if error = run_openssl(args)
          return error
        end
        File.rename(tmp, path)
        nil
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end

    # --- idempotency -----------------------------------------------------

    private def matches?(path : String, privatekey_path : String, certificate_path : String?, temp_files : Array(String) = [] of String) : Bool
      dump = dump_pkcs12(path)
      return false unless dump

      return false unless friendly_name_matches?(dump)
      return false unless key_matches_archive?(dump, privatekey_path)
      return false unless certificate_matches?(dump, certificate_path)
      return false unless other_certificates_match?(dump, temp_files)

      true
    rescue
      false
    end

    private def friendly_name_matches?(dump : String) : Bool
      if (name = @params["friendly_name"]?) && !name.empty?
        return dump.includes?("friendlyName: #{name}")
      end
      true
    end

    private def key_matches_archive?(dump : String, privatekey_path : String) : Bool
      key_in_archive = extract_block(dump, "PRIVATE KEY")
      return false unless key_in_archive
      key_on_disk = normalized_key(privatekey_path)
      return false unless key_on_disk && normalize_pem(key_in_archive) == key_on_disk
      true
    end

    private def certificate_matches?(dump : String, certificate_path : String?) : Bool
      return true unless certificate_path
      certificate_in_archive = extract_block(dump, "CERTIFICATE")
      return false unless certificate_in_archive
      normalize_pem(certificate_in_archive) == normalize_pem(File.read(certificate_path))
    end

    private def other_certificates_match?(dump : String, temp_files : Array(String)) : Bool
      if (other = other_certificates(temp_files)) && !other.empty?
        archive_certs = dump.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map(&.[0])
        return archive_certs.size >= other.size
      end
      true
    end

    # `-nodes` dumps the key unencrypted, so the archive's copy can be
    # compared against the source key regardless of how either side is
    # encrypted at rest.
    private def dump_pkcs12(path : String) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl",
        ["pkcs12", "-in", path, "-nodes", "-passin", "pass:#{passphrase}"],
        output: stdout_io, error: err)
      status.success? ? stdout_io.to_s : nil
    end

    # The archive always holds the key in PKCS#8 form, while the source
    # file may be PKCS#1 - so both sides are canonicalized through
    # `openssl pkey` before comparison rather than compared as text.
    private def normalized_key(path : String) : String?
      args = ["pkey", "-in", path]
      if (key_passphrase = @params["privatekey_passphrase"]?) && !key_passphrase.empty?
        args.concat(["-passin", "pass:#{key_passphrase}"])
      end
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      return nil unless status.success?
      normalize_pem(stdout_io.to_s)
    end

    private def normalize_pem(text : String) : String
      text.lines.map(&.strip).reject(&.empty?).join("\n")
    end

    private def extract_block(text : String, kind : String) : String?
      start_marker = text.index("-----BEGIN #{kind}-----")
      # A PKCS#8 key in the dump is "-----BEGIN PRIVATE KEY-----", but an
      # archive written elsewhere may hold an "ENCRYPTED PRIVATE KEY" or
      # an "RSA PRIVATE KEY" block instead.
      start_marker ||= text.index(/-----BEGIN [A-Z0-9 ]*#{kind}-----/)
      return nil unless start_marker

      end_marker = text.index("-----END", start_marker)
      return nil unless end_marker
      line_end = text.index('\n', end_marker) || text.size
      text[start_marker...line_end]
    end

    # --- reporting --------------------------------------------------------

    private def result(changed : Bool, path : String, privatekey_path : String,
                       backup_file : String?) : PluginResult
      res = PluginResult.new(changed: changed, failed: false, msg: "")
      res.extra["filename"] = JSON::Any.new(path)
      res.extra["privatekey_path"] = JSON::Any.new(privatekey_path)
      res.extra["mode"] = JSON::Any.new(@params["mode"]? || "0400")
      res.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      if true?(@params["return_content"]?) && File.exists?(path)
        res.extra["pkcs12"] = JSON::Any.new(Base64.strict_encode(File.read(path)))
      end
      res
    end

    private def apply_attrs(path : String) : Bool
      return false unless File.exists?(path)
      before = File.info(path).permissions.value
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]? || "0400")
      File.info(path).permissions.value != before
    rescue
      false
    end

    private def run_openssl(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      return nil if status.success?
      "openssl pkcs12 failed: #{err.to_s.strip}"
    end

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

plugin = Krikri::OpensslPkcs12Plugin.new(config)
plugin.run
