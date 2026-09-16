#!/usr/bin/env crystal

require "json"
require "random/secure"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

module Krikri
  # x509_certificate plugin (community.crypto.x509_certificate) -
  # issues certificates from a CSR, either self-signed or signed by a
  # CA you own.
  #
  # Providers: `selfsigned` and `ownca`, which is what every use of this
  # module across the benchmark role corpus asks for (robertdebock/
  # buluma .openssl and .bareos_fd, buluma.ca). `acme`, `entrust` and
  # the removed `assertonly` are not implemented and fail with a clear
  # message rather than silently doing something else.
  #
  # Built on `openssl x509 -req -copy_extensions copyall`, which
  # reproduces the real module's output exactly: the CSR's extensions
  # are carried over, a SubjectKeyIdentifier is added, and for `ownca`
  # an AuthorityKeyIdentifier derived from the CA key - verified
  # extension-for-extension against real module output for both
  # providers.
  #
  # Idempotency mirrors the real backends rather than comparing files
  # (a certificate carries a random serial and fresh timestamps, so no
  # two generated certificates are ever byte-equal):
  #
  #   * the certificate's public key must match the private key/CSR
  #   * its subject and extensions must match the CSR's
  #   * a SubjectKeyIdentifier must be present
  #   * for ownca: the issuer must be the CA's subject, and the
  #     AuthorityKeyIdentifier must match the CA's SubjectKeyIdentifier
  #     (this is what catches a CA that was regenerated under the same
  #     name - the old leaf certificates are no longer valid under it)
  #   * validity timestamps are NOT compared (ignore_timestamps
  #     defaults to true), or every run with a relative `+3650d` would
  #     reissue
  class X509CertificatePlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # The real module's fully-resolved argument_spec (the
    # get_certificate_argument_spec base plus the acme/ownca/selfsigned
    # provider keys and the module's own state/path/backup/return_content,
    # in resolution order) plus the file-common args its
    # add_file_common_args=True injects. Aliases: attributes->attr and
    # selfsigned_not_before/after's camelCase aliases.
    SPEC = {
      "provider"                             => [] of String,
      "force"                                => [] of String,
      "csr_path"                             => [] of String,
      "csr_content"                          => [] of String,
      "ignore_timestamps"                    => [] of String,
      "select_crypto_backend"                 => [] of String,
      "privatekey_path"                      => [] of String,
      "privatekey_content"                   => [] of String,
      "privatekey_passphrase"                 => [] of String,
      "state"                                => [] of String,
      "path"                                 => [] of String,
      "backup"                               => [] of String,
      "return_content"                       => [] of String,
      "acme_accountkey_path"                  => [] of String,
      "acme_challenge_path"                   => [] of String,
      "acme_chain"                           => [] of String,
      "acme_directory"                       => [] of String,
      "ownca_path"                           => [] of String,
      "ownca_content"                        => [] of String,
      "ownca_privatekey_path"                 => [] of String,
      "ownca_privatekey_content"              => [] of String,
      "ownca_privatekey_passphrase"           => [] of String,
      "ownca_digest"                         => [] of String,
      "ownca_version"                        => [] of String,
      "ownca_not_before"                     => [] of String,
      "ownca_not_after"                      => [] of String,
      "ownca_create_subject_key_identifier"   => [] of String,
      "ownca_create_authority_key_identifier" => [] of String,
      "selfsigned_version"                   => [] of String,
      "selfsigned_digest"                    => [] of String,
      "selfsigned_not_before"                 => ["selfsigned_notBefore"],
      "selfsigned_not_after"                  => ["selfsigned_notAfter"],
      "selfsigned_create_subject_key_identifier" => [] of String,
      "mode"                                 => [] of String,
      "owner"                                => [] of String,
      "group"                                => [] of String,
      "seuser"                               => [] of String,
      "serole"                               => [] of String,
      "selevel"                              => [] of String,
      "setype"                               => [] of String,
      "attributes"                           => ["attr"],
      "unsafe_writes"                        => [] of String,
    }

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      temp_files = [] of String
      begin
        path = @params["path"]?
        path = expand_tilde(path.not_nil!)
        state = @params["state"]? || "present"
        check_mode = true?(@params["_ansible_check_mode"]?)

        return remove(path, check_mode) if state == "absent"

        provider = @params["provider"]?
        return failure("state is present but all of the following are missing: provider") unless provider
        unless ["selfsigned", "ownca"].includes?(provider)
          return failure("The provider '#{provider}' is not supported by this implementation; only 'selfsigned' and 'ownca' are.")
        end

        csr_path = resolve_content_param(temp_files, "csr_path", "csr_content")
        return failure("csr_path is required") unless csr_path
        return failure("The certificate signing request file #{csr_path} does not exist") unless File.exists?(csr_path)

        privatekey_path = resolve_content_param(temp_files, "privatekey_path", "privatekey_content")
        ownca_path = resolve_content_param(temp_files, "ownca_path", "ownca_content")
        ownca_privatekey_path = resolve_content_param(temp_files, "ownca_privatekey_path", "ownca_privatekey_content")

        if provider == "selfsigned"
          return failure("privatekey_path is required for the selfsigned provider") unless privatekey_path
          return failure("The private key #{privatekey_path} does not exist") unless File.exists?(privatekey_path)
        else
          return failure("ownca_path is required for the ownca provider") unless ownca_path
          return failure("ownca_privatekey_path is required for the ownca provider") unless ownca_privatekey_path
          return failure("The CA certificate #{ownca_path} does not exist") unless File.exists?(ownca_path)
          return failure("The CA private key #{ownca_privatekey_path} does not exist") unless File.exists?(ownca_privatekey_path)
        end

        base_dir = File.dirname(path)
        return failure("The directory #{base_dir} does not exist or the file is not a directory") unless Dir.exists?(base_dir)

        changed = true?(@params["force"]?) || !File.exists?(path) ||
                  needs_regeneration?(path, provider, privatekey_path, csr_path, ownca_path)

        if changed && !check_mode
          backup_file = backup(path)
          if error = generate(path, provider, privatekey_path, csr_path, ownca_path, ownca_privatekey_path)
            return failure(error)
          end
          # A certificate is public: the umask decides unless the user
          # asked for something specific (matches the real module, which
          # writes 0644-by-umask here rather than the 0600 a private key
          # gets).
          File.chmod(path, 0o666 & ~current_umask) unless @params["mode"]?
          apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
          return result(true, path, privatekey_path, csr_path, backup_file)
        end

        return result(true, path, privatekey_path, csr_path, nil) if changed

        attrs_changed = apply_attrs(path)
        result(attrs_changed, path, privatekey_path, csr_path, nil)
      ensure
        temp_files.each { |file| File.delete(file) rescue nil }
      end
    end

    # Content variants of the path parameters (csr_content,
    # privatekey_content, ownca_content, ownca_privatekey_content) are
    # materialized to temp files and used in place of the path variant
    # whenever the path itself is not given - the real module reads the
    # bytes straight from params.
    private def resolve_content_param(temp_files : Array(String), path_param : String, content_param : String) : String?
      if path_param_value = @params[path_param]?
        return expand_tilde(path_param_value)
      end
      if content = @params[content_param]?
        file = File.tempname("x509-content")
        File.write(file, content)
        temp_files << file
        return file
      end
      nil
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # Real AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required -> types (spec declaration order) -> choices -> required_if
    # -> mutually_exclusive -> unsupported (deferred last).
    private def validate_arguments : PluginResult?
      return missing_required_error(["path"]) unless @params["path"]?

      %w[ownca_version selfsigned_version].each do |param|
        if raw = @params[param]?
          return int_type_error(param, raw) unless raw.to_i32?
        end
      end
      %w[force ignore_timestamps acme_chain ownca_create_authority_key_identifier
         backup return_content unsafe_writes].each do |param|
        if raw = @params[param]?
          return bool_type_error(param, raw) unless bool_convertible?(raw)
        end
      end

      {"provider"                             => %w[acme ownca selfsigned],
       "select_crypto_backend"                 => %w[auto cryptography],
       "ownca_version"                        => %w[3],
       "ownca_create_subject_key_identifier"   => %w[create_if_not_provided always_create never_create],
       "selfsigned_version"                    => %w[3],
       "selfsigned_create_subject_key_identifier" => %w[create_if_not_provided always_create never_create],
       "state"                                => %w[present absent]}.each do |param, allowed|
        if value = @params[param]?
          unless allowed.includes?(value)
            return choices_error(param, allowed, value)
          end
        end
      end

      if (@params["state"]? || "present") == "present" && !@params["provider"]?
        return failure("state is present but all of the following are missing: provider")
      end

      # The real backends run every not_before/not_after through
      # get_relative_time_option before touching any file.
      %w[ownca_not_before ownca_not_after selfsigned_not_before selfsigned_not_after].each do |param|
        if value = @params[param]?
          unless crypto_time_spec_valid?(value)
            return failure("The time spec \"#{value}\" for #{param} is invalid")
          end
        end
      end

      [%w[csr_path csr_content], %w[privatekey_path privatekey_content],
       %w[ownca_path ownca_content],
       %w[ownca_privatekey_path ownca_privatekey_content]].each do |pair|
        if pair.all? { |param| @params[param]? }
          return failure("parameters are mutually exclusive: #{pair.join("|")}")
        end
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.x509_certificate", unsupported, SPEC)
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

    # --- issuance -------------------------------------------------------

    private def generate(path : String, provider : String, privatekey_path : String?,
                         csr_path : String, ownca_path : String?, ownca_privatekey_path : String?) : String?
      tmp = File.tempname("x509-cert", dir: File.dirname(path))
      ext_file = File.tempname("x509-ext")
      begin
        digest = @params[provider == "ownca" ? "ownca_digest" : "selfsigned_digest"]? || "sha256"
        days = validity_days(provider)

        args = ["x509", "-req", "-in", csr_path, "-out", tmp, "-#{digest}",
                "-days", days.to_s, "-set_serial", serial.to_s, "-copy_extensions", "copyall"]

        # The real backends create a SubjectKeyIdentifier (and an
        # AuthorityKeyIdentifier for ownca) when the CSR does not
        # provide one - create_if_not_provided is the default and
        # ownca_create_authority_key_identifier defaults to true. Bookworm's
        # OpenSSL 3.0 does not auto-add any SKI, so without this the
        # generated cert never matches the real module's output and
        # every re-run regenerates.
        ext_lines = [] of String
        ski_param = provider == "ownca" ? "ownca_create_subject_key_identifier" : "selfsigned_create_subject_key_identifier"
        if @params[ski_param]? != "never_create" && !csr_has_extension?(csr_path, "Subject Key Identifier")
          ext_lines << "subjectKeyIdentifier=hash"
        end
        if provider == "ownca" && true?(@params["ownca_create_authority_key_identifier"]? || "true") &&
           !csr_has_extension?(csr_path, "Authority Key Identifier")
          ext_lines << "authorityKeyIdentifier=keyid"
        end
        unless ext_lines.empty?
          File.write(ext_file, ext_lines.join("\n") + "\n")
          args += ["-extfile", ext_file]
        end

        if error = add_signing_args(args, provider, privatekey_path, ownca_path, ownca_privatekey_path)
          return error
        end

        if error = run_openssl(args)
          return error
        end
        File.rename(tmp, path)
        nil
      ensure
        File.delete(tmp) if File.exists?(tmp)
        File.delete(ext_file) if File.exists?(ext_file)
      end
    end

    private def csr_has_extension?(csr_path : String, label : String) : Bool
      (extension_lines(csr_path, csr: true) || [] of String).any?(&.starts_with?(label))
    end

    private def add_signing_args(args : Array(String), provider : String, privatekey_path : String?,
                                 ownca_path : String?, ownca_privatekey_path : String?) : String?
      if provider == "selfsigned"
        return "privatekey_path is required for the selfsigned provider" unless privatekey_path
        args.concat(["-signkey", privatekey_path])
        if (passphrase = @params["privatekey_passphrase"]?) && !passphrase.empty?
          args.concat(["-passin", "pass:#{passphrase}"])
        end
      else
        return "ownca_path and ownca_privatekey_path are required for the ownca provider" unless ownca_path && ownca_privatekey_path
        args.concat(["-CA", ownca_path, "-CAkey", ownca_privatekey_path])
        if (passphrase = @params["ownca_privatekey_passphrase"]?) && !passphrase.empty?
          args.concat(["-passin", "pass:#{passphrase}"])
        end
      end
      nil
    end

    # The real module's serial is a 20-byte random integer. This one is
    # 63 bits so it survives the JSON round trip as a real integer (the
    # `serial_number` return value is an int there, and Crystal's JSON
    # has no bignum) - still random per certificate, which is all the
    # uniqueness requirement is.
    private def serial : Int64
      (Random::Secure.rand(Int64::MAX - 1) + 1).to_i64
    end

    # `+3650d` and friends: relative offsets are what the module
    # defaults to and what roles use. An absolute ASN.1 timestamp
    # (YYYYMMDDHHMMSSZ) is converted to a day count from now, since
    # `openssl x509 -req` takes a duration rather than an end date on
    # the OpenSSL versions this targets.
    private def validity_days(provider : String) : Int32
      raw = @params[provider == "ownca" ? "ownca_not_after" : "selfsigned_not_after"]? || "+3650d"

      if days = relative_days(raw)
        return days
      end

      if days = absolute_days(raw)
        return days
      end

      3650
    end

    private def relative_days(raw : String) : Int32?
      match = raw.match(/\A\+(\d+)([smhdw])\z/) || return nil
      amount = match[1].to_i64
      seconds = case match[2]
                when "s" then amount
                when "m" then amount * 60
                when "h" then amount * 3600
                when "w" then amount * 604800
                else          amount * 86400
                end
      days = (seconds / 86400.0).ceil.to_i
      days < 1 ? 1 : days
    end

    private def absolute_days(raw : String) : Int32?
      match = raw.match(/\A(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z\z/) || return nil
      target = Time.utc(match[1].to_i, match[2].to_i, match[3].to_i,
        match[4].to_i, match[5].to_i, match[6].to_i)
      days = ((target - Time.utc).total_days).ceil.to_i
      days < 1 ? 1 : days
    end

    # --- idempotency -----------------------------------------------------

    private def needs_regeneration?(path : String, provider : String, privatekey_path : String?,
                                    csr_path : String, ownca_path : String?) : Bool
      cert_pubkey = pubkey_of(["x509", "-in", path, "-noout", "-pubkey"])
      return true unless cert_pubkey

      return true if privatekey_mismatch?(cert_pubkey, privatekey_path)

      csr_pubkey = pubkey_of(["req", "-in", csr_path, "-noout", "-pubkey"])
      return true unless csr_pubkey && csr_pubkey == cert_pubkey

      return true unless subject_matches?(path, csr_path)
      return true unless extensions_match?(path, csr_path)
      if provider == "ownca"
        ca_path = ownca_path || return true
        return true if ownca_matches?(path, ca_path)
      end

      false
    end

    private def privatekey_mismatch?(cert_pubkey : String, privatekey_path : String?) : Bool
      return false unless privatekey_path
      args = ["pkey", "-in", privatekey_path, "-pubout"]
      if (passphrase = @params["privatekey_passphrase"]?) && !passphrase.empty?
        args.concat(["-passin", "pass:#{passphrase}"])
      end
      key_pubkey = pubkey_of(args)
      !(key_pubkey && key_pubkey == cert_pubkey)
    end

    private def subject_matches?(path : String, csr_path : String) : Bool
      cert_subject = field(["x509", "-in", path, "-noout", "-subject", "-nameopt", "RFC2253"])
      csr_subject = field(["req", "-in", csr_path, "-noout", "-subject", "-nameopt", "RFC2253"])
      return false unless cert_subject && csr_subject
      cert_subject.sub(/\Asubject=\s*/, "") == csr_subject.sub(/\Asubject=\s*/, "")
    end

    private def extensions_match?(path : String, csr_path : String) : Bool
      cert_extensions = extension_lines(path, csr: false)
      csr_extensions = extension_lines(csr_path, csr: true)
      return false unless cert_extensions && csr_extensions
      # The certificate legitimately carries extensions the CSR does not
      # (SubjectKeyIdentifier, and AuthorityKeyIdentifier for ownca), so
      # this is containment, not equality - exactly what the real
      # module's own _check_csr does.
      return false unless csr_extensions.all? { |line| cert_extensions.includes?(line) }

      # create_subject_key_identifier defaults to create_if_not_provided.
      cert_extensions.any?(&.starts_with?("X509v3 Subject Key Identifier"))
    end

    private def ownca_matches?(path : String, ownca_path : String) : Bool
      cert_issuer = field(["x509", "-in", path, "-noout", "-issuer", "-nameopt", "RFC2253"])
      ca_subject = field(["x509", "-in", ownca_path, "-noout", "-subject", "-nameopt", "RFC2253"])
      return false unless cert_issuer && ca_subject
      return false unless cert_issuer.sub(/\Aissuer=\s*/, "") == ca_subject.sub(/\Asubject=\s*/, "")

      # A CA regenerated under the same name is the case a subject
      # comparison alone cannot see; its key identifier changes.
      ca_ski = key_identifier(ownca_path, "X509v3 Subject Key Identifier")
      cert_aki = key_identifier(path, "X509v3 Authority Key Identifier")
      return false if ca_ski.nil? && cert_aki.nil?
      return true if cert_aki.nil? || ca_ski.nil?
      ca_ski != cert_aki
    end

    private def pubkey_of(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      status.success? ? stdout_io.to_s.strip : nil
    end

    private def field(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      status.success? ? stdout_io.to_s.strip : nil
    end

    # The extension block of `-text`, flattened to whitespace-normalized
    # lines so a certificate's block and a CSR's "Requested Extensions"
    # block (which is printed at a deeper indent) compare directly.
    private def extension_lines(path : String, csr : Bool) : Array(String)?
      args = csr ? ["req", "-in", path, "-noout", "-text"] : ["x509", "-in", path, "-noout", "-text"]
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      return nil unless status.success?

      lines = [] of String
      inside = false
      stdout_io.to_s.each_line do |line|
        stripped = line.strip
        if stripped == "X509v3 extensions:" || stripped == "Requested Extensions:"
          inside = true
          next
        end
        next unless inside
        break if stripped.starts_with?("Signature Algorithm") || stripped.starts_with?("Signature Value")
        lines << stripped unless stripped.empty?
      end
      lines
    end

    private def key_identifier(path : String, label : String) : String?
      lines = extension_lines(path, csr: false)
      return nil unless lines
      index = lines.index(&.starts_with?(label))
      return nil unless index
      lines[index + 1]?
    end

    # --- reporting --------------------------------------------------------

    private def result(changed : Bool, path : String, privatekey_path : String?,
                       csr_path : String, backup_file : String?) : PluginResult
      res = PluginResult.new(changed: changed, failed: false, msg: "")
      res.extra["filename"] = JSON::Any.new(path)
      res.extra["privatekey"] = JSON::Any.new(privatekey_path) if privatekey_path
      res.extra["csr"] = JSON::Any.new(csr_path)
      res.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file

      add_certificate_details(res, path) if File.exists?(path)
      res
    end

    private def add_certificate_details(res : PluginResult, path : String) : Nil
      add_dates(res, path)
      add_serial(res, path)
      res.extra["certificate"] = JSON::Any.new(File.read(path)) if true?(@params["return_content"]?)
    end

    private def add_dates(res : PluginResult, path : String) : Nil
      return unless dates = field(["x509", "-in", path, "-noout", "-dates"])
      dates.each_line do |line|
        key, _, value = line.partition('=')
        asn1 = asn1_time(value.strip)
        res.extra["notBefore"] = JSON::Any.new(asn1) if key == "notBefore" && asn1
        res.extra["notAfter"] = JSON::Any.new(asn1) if key == "notAfter" && asn1
      end
    end

    private def add_serial(res : PluginResult, path : String) : Nil
      return unless serial_hex = field(["x509", "-in", path, "-noout", "-serial"])
      return unless value = serial_hex.split('=').last?
      numeric = value.to_i64?(16)
      # Falls back to the hex text for a certificate issued
      # elsewhere with a serial too wide for an Int64 (the real
      # module's own 20-byte serials, for instance).
      res.extra["serial_number"] = numeric ? JSON::Any.new(numeric) : JSON::Any.new(value)
    end

    # openssl prints "Aug 26 14:03:39 2026 GMT"; the module reports the
    # ASN.1 form "20260826140339Z".
    private def asn1_time(value : String) : String?
      time = Time.parse_utc(value.sub(" GMT", ""), "%b %e %H:%M:%S %Y")
      time.to_s("%Y%m%d%H%M%SZ")
    rescue
      nil
    end

    private def apply_attrs(path : String) : Bool
      return false unless File.exists?(path)
      before = File.info(path).permissions.value
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      File.info(path).permissions.value != before
    rescue
      false
    end

    private def run_openssl(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      return nil if status.success?
      "openssl x509 failed: #{err.to_s.strip}"
    end

    private def current_umask : UInt32
      mask = LibC.umask(0o022_u32)
      LibC.umask(mask)
      mask.to_u32
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

lib LibC
  fun umask(mask : ModeT) : ModeT
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::X509CertificatePlugin.new(config)
plugin.run
