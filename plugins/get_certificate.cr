#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/x509_cert_info"

module Krikri
  # get_certificate plugin (community.crypto.get_certificate) - connects
  # to host:port over TLS, retrieves the certificate the server presents,
  # and reports its facts (subject/issuer/validity/extensions/
  # fingerprints) through the shared X509CertInfo helper. The real module
  # writes nothing to disk and never changes state - the cert is only
  # returned in the `cert` fact (earlier revisions here invented a
  # `path:` writing feature the real module does not have).
  #
  # Params (the real module's argument_spec, no aliases): host, port
  # (both required), ca_cert (verifies the chain against a PEM file - the
  # real module's caveat applies: this checks the chain, not that the
  # cert is valid for the host), server_name (SNI, defaults to host),
  # timeout, proxy_host/proxy_port (HTTP CONNECT via s_client -proxy,
  # proxy_port defaulting to 8080 like the real module), starttls
  # (mysql), ciphers, asn1_base64, tls_ctx_options, select_crypto_backend
  # (accepted; only the OpenSSL CLI path is implemented),
  # get_certificate_chain (the unverified chain comes from the same
  # connection; verified_chain is not implemented - see KNOWN_MISSING.md).
  #
  # Real AnsibleModule validation order is mirrored: required -> types
  # (spec declaration order) -> choices -> unsupported (deferred last).
  class GetCertificatePlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    SPEC = {
      "ca_cert"               => [] of String,
      "host"                  => [] of String,
      "port"                  => [] of String,
      "proxy_host"            => [] of String,
      "proxy_port"            => [] of String,
      "server_name"           => [] of String,
      "timeout"               => [] of String,
      "select_crypto_backend" => [] of String,
      "starttls"              => [] of String,
      "ciphers"               => [] of String,
      "asn1_base64"           => [] of String,
      "tls_ctx_options"       => [] of String,
      "get_certificate_chain" => [] of String,
    }

    def execute : PluginResult
      if err = validate_arguments
        return err
      end
      host = @params["host"].not_nil!
      port = @params["port"].not_nil!.to_i

      return failure("ca_cert file does not exist") if (ca_cert = @params["ca_cert"]?) && !File.exists?(expand_tilde(ca_cert))

      timeout = @params["timeout"]?.try(&.to_i) || 10
      sni = @params["server_name"]? || host
      proxy = @params["proxy_host"]?.try do |proxy_host|
        "#{proxy_host}:#{@params["proxy_port"]?.try(&.to_i) || 8080}"
      end

      pems = fetch_certs(host, port, sni, timeout, ca_cert.try { |value| expand_tilde(value) }, proxy)
      if pems.nil? || pems.empty?
        return failure("Failed to get cert from #{host}:#{port}")
      end
      cert_pem = pems.first

      info = X509CertInfo.parse(cert_pem)
      return failure("Unable to parse the retrieved certificate") unless info

      res = PluginResult.new(changed: false, failed: false, msg: "")
      info.each do |key, value|
        res.extra[key] = value
      end
      res.extra["cert"] = JSON::Any.new(cert_pem)
      if true?(@params["get_certificate_chain"]?) && pems.size > 1
        res.extra["unverified_chain"] = JSON::Any.new(pems.map { |pem| JSON::Any.new(pem) })
      end
      res
    end

    # Real AnsibleModule validation order: required -> types (spec
    # declaration order) -> choices -> unsupported (deferred last).
    private def validate_arguments : PluginResult?
      missing = %w[host port].select { |param| @params[param]?.nil? }
      return missing_required_error(missing) unless missing.empty?

      {"port" => :int, "proxy_port" => :int, "timeout" => :int,
       "asn1_base64" => :bool, "get_certificate_chain" => :bool}.each do |param, type|
        next unless raw = @params[param]?
        if type == :int
          next if raw.to_i32?
          return int_type_error(param, raw)
        else
          next if bool_convertible?(raw)
          return bool_type_error(param, raw)
        end
      end

      backend = @params["select_crypto_backend"]? || "auto"
      unless %w[auto cryptography].includes?(backend)
        return choices_error("select_crypto_backend", %w[auto cryptography], backend)
      end
      if (starttls = @params["starttls"]?) && starttls != "mysql"
        return choices_error("starttls", %w[mysql], starttls)
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.get_certificate", unsupported, SPEC)
      end
      nil
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # s_client prints the server's chain (leaf first) as PEM blocks on
    # stdout. With ca_cert the connection additionally demands a chain
    # that verifies against that store (the real module's validation
    # scope: the chain, not the hostname). With proxy_host the TCP hop
    # goes through an HTTP CONNECT proxy (s_client -proxy).
    private def fetch_certs(host : String, port : Int32, sni : String, timeout : Int32, ca_cert : String?, proxy : String?) : Array(String)?
      args = ["s_client", "-connect", "#{host}:#{port}", "-servername", sni]
      args << "-proxy" << proxy if proxy
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
    rescue IO::TimeoutError
      nil
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::GetCertificatePlugin.new(config)
plugin.run
