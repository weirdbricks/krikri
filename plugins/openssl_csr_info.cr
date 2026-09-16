#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/x509_cert_info"

module Krikri
  # openssl_csr_info plugin (community.crypto.openssl_csr_info) - reads
  # a PKCS#10 certificate request and reports its facts. Read-only: no
  # path is written, check_mode changes nothing.
  #
  # Backed by the `openssl` CLI through the shared X509CertInfo.parse_csr
  # helper (see its comment for the field-by-field provenance against
  # the real module's own get_info). Params: path (a PEM or DER request
  # file) or content (PEM text), exactly one of the two, matching the
  # real module's required_one_of plus mutually_exclusive pair.
  #
  # Known divergence, deliberate: extensions_by_oid,
  # subject_key_identifier, authority_key_identifier and the
  # name_constraints_* fields are not returned (they need an ASN.1
  # decoder this tree does not carry) - same cut as
  # x509_certificate_info's extensions_by_oid.
  class OpensslCsrInfoPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # The real module's argument_spec - no file-common args (no
    # add_file_common_args), no aliases.
    SPEC = {
      "path"                  => [] of String,
      "content"               => [] of String,
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

      csr_pem = extract_pem(raw)
      if csr_pem.nil? && !raw.includes?("-----BEGIN CERTIFICATE REQUEST-----")
        csr_pem = convert_der(raw.to_slice, path)
      end
      return failure("Unable to parse the certificate request") unless csr_pem

      info = X509CertInfo.parse_csr(csr_pem)
      return failure("Unable to parse the certificate request") unless info

      res = PluginResult.new(changed: false, failed: false, msg: "")
      info.each do |key, value|
        res.extra[key] = value
      end
      res
    end

    # Real AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required_one_of -> types -> choices -> mutually_exclusive ->
    # unsupported (deferred last). Types are all str/path here, nothing
    # to convert.
    private def validate_arguments : PluginResult?
      if @params["path"]?.nil? && @params["content"]?.nil?
        return failure("one of the following is required: path, content")
      end

      {"name_encoding"         => %w[ignore idna unicode],
       "select_crypto_backend" => %w[auto cryptography]}.each do |param, allowed|
        if value = @params[param]?
          unless allowed.includes?(value)
            return choices_error(param, allowed, value)
          end
        end
      end

      if @params["path"]? && @params["content"]?
        return failure("parameters are mutually exclusive: path|content")
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.openssl_csr_info", unsupported, SPEC)
      end
      nil
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # A PEM file may hold the request among other blocks; the real
    # module reads the first certificate request.
    private def extract_pem(raw : String) : String?
      start = raw.index("-----BEGIN CERTIFICATE REQUEST-----")
      return nil unless start
      stop = raw.index("-----END CERTIFICATE REQUEST-----", start)
      return nil unless stop
      raw[start..stop + "-----END CERTIFICATE REQUEST-----".size - 1] + "\n"
    end

    # A DER request (the real module auto-detects the encoding); openssl
    # converts it to PEM for the text parser.
    private def convert_der(raw : Bytes, path : String?) : String?
      der_file = File.tempname("csrinfo-der")
      pem_file = File.tempname("csrinfo-pem")
      File.write(der_file, raw)
      begin
        stdout_io = IO::Memory.new
        err = IO::Memory.new
        status = Process.run("openssl", ["req", "-in", der_file, "-inform", "DER", "-out", pem_file], output: stdout_io, error: err)
        return nil unless status.success?
        File.read(pem_file)
      ensure
        File.delete(der_file) if File.exists?(der_file)
        File.delete(pem_file) if File.exists?(pem_file)
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::OpensslCsrInfoPlugin.new(config)
plugin.run
