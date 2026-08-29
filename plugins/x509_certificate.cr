#!/usr/bin/env crystal

require "json"
require "random/secure"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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
    def execute : PluginResult
      path = @params["path"]?
      return failure("missing required arguments: path") unless path

      path = expand_tilde(path)
      state = @params["state"]? || "present"
      check_mode = true?(@params["check_mode"]?)

      return remove(path, check_mode) if state == "absent"

      provider = @params["provider"]?
      return failure("state is present but all of the following are missing: provider") unless provider
      unless ["selfsigned", "ownca"].includes?(provider)
        return failure("The provider '#{provider}' is not supported by this implementation; only 'selfsigned' and 'ownca' are.")
      end

      csr_path = @params["csr_path"]?.try { |value| expand_tilde(value) }
      return failure("csr_path is required") unless csr_path
      return failure("The certificate signing request file #{csr_path} does not exist") unless File.exists?(csr_path)

      privatekey_path = @params["privatekey_path"]?.try { |value| expand_tilde(value) }
      ownca_path = @params["ownca_path"]?.try { |value| expand_tilde(value) }
      ownca_privatekey_path = @params["ownca_privatekey_path"]?.try { |value| expand_tilde(value) }

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
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
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
      begin
        digest = @params[provider == "ownca" ? "ownca_digest" : "selfsigned_digest"]? || "sha256"
        days = validity_days(provider)

        args = ["x509", "-req", "-in", csr_path, "-out", tmp, "-#{digest}",
                "-days", days.to_s, "-set_serial", serial.to_s, "-copy_extensions", "copyall"]

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

        if error = run_openssl(args)
          return error
        end
        File.rename(tmp, path)
        nil
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
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

      if match = raw.match(/\A\+(\d+)([smhdw])\z/)
        amount = match[1].to_i64
        seconds = case match[2]
                  when "s" then amount
                  when "m" then amount * 60
                  when "h" then amount * 3600
                  when "w" then amount * 604800
                  else          amount * 86400
                  end
        days = (seconds / 86400.0).ceil.to_i
        return days < 1 ? 1 : days
      end

      if match = raw.match(/\A(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z\z/)
        target = Time.utc(match[1].to_i, match[2].to_i, match[3].to_i,
          match[4].to_i, match[5].to_i, match[6].to_i)
        days = ((target - Time.utc).total_days).ceil.to_i
        return days < 1 ? 1 : days
      end

      3650
    end

    # --- idempotency -----------------------------------------------------

    private def needs_regeneration?(path : String, provider : String, privatekey_path : String?,
                                    csr_path : String, ownca_path : String?) : Bool
      cert_pubkey = pubkey_of(["x509", "-in", path, "-noout", "-pubkey"])
      return true unless cert_pubkey

      if privatekey_path
        args = ["pkey", "-in", privatekey_path, "-pubout"]
        if (passphrase = @params["privatekey_passphrase"]?) && !passphrase.empty?
          args.concat(["-passin", "pass:#{passphrase}"])
        end
        key_pubkey = pubkey_of(args)
        return true unless key_pubkey && key_pubkey == cert_pubkey
      end

      csr_pubkey = pubkey_of(["req", "-in", csr_path, "-noout", "-pubkey"])
      return true unless csr_pubkey && csr_pubkey == cert_pubkey

      cert_subject = field(["x509", "-in", path, "-noout", "-subject", "-nameopt", "RFC2253"])
      csr_subject = field(["req", "-in", csr_path, "-noout", "-subject", "-nameopt", "RFC2253"])
      return true unless cert_subject && csr_subject
      return true unless cert_subject.sub(/\Asubject=\s*/, "") == csr_subject.sub(/\Asubject=\s*/, "")

      cert_extensions = extension_lines(path, csr: false)
      csr_extensions = extension_lines(csr_path, csr: true)
      return true unless cert_extensions && csr_extensions
      # The certificate legitimately carries extensions the CSR does not
      # (SubjectKeyIdentifier, and AuthorityKeyIdentifier for ownca), so
      # this is containment, not equality - exactly what the real
      # module's own _check_csr does.
      return true unless csr_extensions.all? { |line| cert_extensions.includes?(line) }

      # create_subject_key_identifier defaults to create_if_not_provided.
      return true unless cert_extensions.any?(&.starts_with?("X509v3 Subject Key Identifier"))

      if provider == "ownca" && ownca_path
        cert_issuer = field(["x509", "-in", path, "-noout", "-issuer", "-nameopt", "RFC2253"])
        ca_subject = field(["x509", "-in", ownca_path, "-noout", "-subject", "-nameopt", "RFC2253"])
        return true unless cert_issuer && ca_subject
        return true unless cert_issuer.sub(/\Aissuer=\s*/, "") == ca_subject.sub(/\Asubject=\s*/, "")

        # A CA regenerated under the same name is the case a subject
        # comparison alone cannot see; its key identifier changes.
        ca_ski = key_identifier(ownca_path, "X509v3 Subject Key Identifier")
        cert_aki = key_identifier(path, "X509v3 Authority Key Identifier")
        return true if ca_ski && cert_aki && ca_ski != cert_aki
      end

      false
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

      if File.exists?(path)
        if dates = field(["x509", "-in", path, "-noout", "-dates"])
          dates.each_line do |line|
            key, _, value = line.partition('=')
            asn1 = asn1_time(value.strip)
            res.extra["notBefore"] = JSON::Any.new(asn1) if key == "notBefore" && asn1
            res.extra["notAfter"] = JSON::Any.new(asn1) if key == "notAfter" && asn1
          end
        end
        if serial_hex = field(["x509", "-in", path, "-noout", "-serial"])
          if value = serial_hex.split('=').last?
            numeric = value.to_i64?(16)
            # Falls back to the hex text for a certificate issued
            # elsewhere with a serial too wide for an Int64 (the real
            # module's own 20-byte serials, for instance).
            res.extra["serial_number"] = numeric ? JSON::Any.new(numeric) : JSON::Any.new(value)
          end
        end
        res.extra["certificate"] = JSON::Any.new(File.read(path)) if true?(@params["return_content"]?)
      end
      res
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

plugin = CrystalPlay::X509CertificatePlugin.new(config)
plugin.run
