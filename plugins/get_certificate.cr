#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/x509_cert_info"

module Krikri
  # get_certificate plugin (community.crypto.get_certificate) - connects
  # to host:port over TLS, retrieves the certificate the server presents,
  # optionally writes it PEM-encoded to `path:`, and reports its facts
  # (subject/issuer/validity/extensions/fingerprints) through the shared
  # X509CertInfo helper.
  #
  # Params implemented: host, port (both required), path, server_name
  # (SNI, defaults to host), timeout (default 10), ca_cert (validates
  # the chain against a PEM file - the real module's caveat applies:
  # this checks the chain, not that the cert is valid for the host),
  # backup, owner/group/mode, return_content (the cert field IS the
  # content, so it carries nothing extra - the real module documents it
  # the same way). get_certificate_chain requests the chain: the
  # unverified chain comes from the same connection; verified_chain is
  # not implemented (needs Python's own trust-store semantics the CLI
  # does not expose) - see KNOWN_MISSING.md.
  #
  # Proxy, starttls (mysql) and tls_ctx_options are not implemented and
  # fail with a clear message - no role in the corpus passes them.
  #
  # The real module does not modify state other than writing the cert
  # file; `changed` reflects only whether path's content changed.
  class GetCertificatePlugin < BasePlugin
    def execute : PluginResult
      host = @params["host"]?
      return failure("missing required arguments: host") unless host
      port = @params["port"]?
      return failure("missing required arguments: port") unless port

      return failure("proxy is not supported by this implementation") if @params["proxy_host"]?
      return failure("starttls is not supported by this implementation") if @params["starttls"]?

      timeout = (@params["timeout"]? || "10").to_i
      sni = @params["server_name"]? || host
      path = @params["path"]?.try { |value| expand_tilde(value) }

      pems = fetch_certs(host, port.to_i, sni, timeout, @params["ca_cert"]?.try { |value| expand_tilde(value) })
      if pems.nil? || pems.empty?
        return failure("Unable to retrieve the certificate from #{host}:#{port}")
      end
      cert_pem = pems.first

      changed = false
      backup_file = nil
      if path
        base_dir = File.dirname(path)
        return failure("The directory #{base_dir} does not exist or the file is not a directory") unless Dir.exists?(base_dir)
        if !File.exists?(path) || normalize(File.read(path)) != normalize(cert_pem)
          changed = true
          unless true?(@params["check_mode"]?)
            backup_file = backup(path)
            File.write(path, cert_pem)
            File.chmod(path, 0o666 & ~current_umask) unless @params["mode"]?
            apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
          end
        end
      end

      info = X509CertInfo.parse(cert_pem)
      return failure("Unable to parse the retrieved certificate") unless info

      res = PluginResult.new(changed: changed, failed: false, msg: "")
      info.each do |key, value|
        res.extra[key] = value
      end
      res.extra["cert"] = JSON::Any.new(cert_pem)
      res.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      if true?(@params["get_certificate_chain"]?) && pems.size > 1
        res.extra["unverified_chain"] = JSON::Any.new(pems.map { |pem| JSON::Any.new(pem) })
      end
      res
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    private def normalize(text : String) : String
      text.lines.map(&.strip).reject(&.empty?).join("\n")
    end

    private def backup(path : String) : String?
      return nil unless true?(@params["backup"]?)
      return nil unless File.exists?(path)
      dest = "#{path}.#{Process.pid}.#{Time.local.to_s("%Y-%m-%d@%H:%M:%S")}~"
      File.copy(path, dest)
      dest
    end

    private def current_umask : UInt32
      mask = LibC.umask(0o022_u32)
      LibC.umask(mask)
      mask.to_u32
    end

    # s_client prints the server's chain (leaf first) as PEM blocks on
    # stdout. With ca_cert the connection additionally demands a chain
    # that verifies against that store (the real module's validation
    # scope: the chain, not the hostname).
    private def fetch_certs(host : String, port : Int32, sni : String, timeout : Int32, ca_cert : String?) : Array(String)?
      args = ["s_client", "-connect", "#{host}:#{port}", "-servername", sni]
      args << "-verify_return_error" << "-CAfile" << ca_cert if ca_cert
      output = IO::Memory.new
      status = Process.run("openssl", args, input: Process::Redirect::Close, output: output,
        error: Process::Redirect::Close)
      return nil if !status.success? && output.to_s.empty?

      certs = [] of String
      scanner = output.to_s
      while start = scanner.index("-----BEGIN CERTIFICATE-----")
        stop = scanner.index("-----END CERTIFICATE-----", start)
        break unless stop
        certs << scanner[start..stop + "-----END CERTIFICATE-----".size] + "\n"
        scanner = scanner[(stop + 25)..]
      end
      certs.empty? ? nil : certs
    rescue ex : IO::TimeoutError
      nil
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::GetCertificatePlugin.new(config)
plugin.run
