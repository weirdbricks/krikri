#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
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
    include PluginHelpers::AnsibleArgValidation

    # The real module's argument_spec - no file-common args (no
    # add_file_common_args), no aliases.
    SPEC = {
      "path"                  => [] of String,
      "content"               => [] of String,
      "valid_at"              => [] of String,
      "name_encoding"         => [] of String,
      "select_crypto_backend" => [] of String,
    }

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      path = @params["path"]?.try { |value| expand_tilde(value) }
      content = @params["content"]?

      if path.nil? == content.nil?
        return failure("parameters are mutually exclusive: path|content")
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

    # Real AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required_one_of -> types -> choices -> mutually_exclusive ->
    # unsupported (deferred last). Types are str/path/dict here; the
    # dict-typed valid_at's elements each must be a string (a check the
    # real module runs right before parsing, failing with the same
    # wording).
    private def validate_arguments : PluginResult?
      if @params["path"]?.nil? && @params["content"]?.nil?
        return failure("one of the following is required: path, content")
      end

      if value = @params["name_encoding"]?
        unless %w[ignore idna unicode].includes?(value)
          return choices_error("name_encoding", %w[ignore idna unicode], value)
        end
      end
      if value = @params["select_crypto_backend"]?
        unless %w[auto cryptography].includes?(value)
          return choices_error("select_crypto_backend", %w[auto cryptography], value)
        end
      end

      if @params["path"]? && @params["content"]?
        return failure("parameters are mutually exclusive: path|content")
      end

      if raw = @params["valid_at"]?
        if parsed = (JSON.parse(raw).as_h? rescue nil)
          parsed.each do |key, entry|
            unless entry.as_s?
              return failure("The value for valid_at.#{key} must be of type string (got #{entry.class.to_s.split("::").last})")
            end
          end
          parsed.each do |key, entry|
            spec = entry.as_s?
            if spec && !crypto_time_spec_valid?(spec)
              return failure("The time spec \"#{spec}\" for valid_at.#{key} is invalid")
            end
          end
        end
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.x509_certificate_info", unsupported, SPEC)
      end
      nil
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
