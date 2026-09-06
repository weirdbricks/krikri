#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/x509_cert_info"

module Krikri
  # x509_certificate_info plugin (community.crypto.x509_certificate_info)
  # - reads a certificate and reports its facts. Read-only: no path is
  # written, no idempotency to maintain, check_mode changes nothing.
  #
  # Backed by the `openssl` CLI through the shared X509CertInfo helper
  # (see its header for the field-by-field provenance). Params:
  # path (a PEM or DER certificate file) or content (PEM text), exactly
  # one of the two, matching the real module's required_one_of plus
  # mutually_exclusive pair.
  #
  # Known divergence, deliberate: `extensions_by_oid` is not returned
  # (needs an ASN.1 decoder this tree does not carry) - see the helper's
  # own header.
  class X509CertificateInfoPlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]?.try { |value| expand_tilde(value) }
      content = @params["content"]?

      if path.nil? == content.nil?
        return failure("One of path or content must be specified, but not both")
      end

      if path
        return failure("Unable to read the file #{path}") unless File.readable?(path)
        raw = File.read(path)
      else
        raw = content || ""
      end

      cert_pem = extract_pem(raw)
      if cert_pem.nil? && !raw.includes?("-----BEGIN CERTIFICATE-----")
        cert_pem = convert_der(raw, path)
      end
      return failure("Unable to parse the certificate") unless cert_pem

      info = X509CertInfo.parse(cert_pem)
      return failure("Unable to parse the certificate") unless info

      res = PluginResult.new(changed: false, failed: false, msg: "")
      info.each do |key, value|
        res.extra[key] = value
      end
      res
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # A PEM file may hold the certificate among other blocks (a fullchain
    # bundle); the real module reads the first certificate.
    private def extract_pem(raw : String) : String?
      start = raw.index("-----BEGIN CERTIFICATE-----")
      return nil unless start
      stop = raw.index("-----END CERTIFICATE-----", start)
      return nil unless stop
      raw[start..stop + "-----END CERTIFICATE-----".size] + "\n"
    end

    # DER certificates pass through the same `openssl x509` CLI - it
    # accepts both formats from a file, so a non-PEM file is re-read by
    # openssl directly rather than decoded here.
    private def convert_der(raw : String, path : String?) : String?
      return nil unless path
      stdout_io = IO::Memory.new
      status = Process.run("openssl", ["x509", "-in", path, "-outform", "PEM"], output: stdout_io)
      status.success? ? stdout_io.to_s : nil
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::X509CertificateInfoPlugin.new(config)
plugin.run
