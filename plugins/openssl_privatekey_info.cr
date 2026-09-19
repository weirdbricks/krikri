#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/x509_cert_info"

module Krikri
  # openssl_privatekey_info plugin
  # (community.crypto.openssl_privatekey_info) - loads a private key and
  # reports its facts. Read-only.
  #
  # Result shape matched against the real module (community.crypto 3.1.1):
  #
  #   can_load_key / can_parse_key - always present; the module FAILS
  #     (rather than returning) when the key cannot be parsed, with
  #     can_parse_key: false carried in the failure result
  #   public_key - the key's public key in PEM (SubjectPublicKeyInfo)
  #   public_key_fingerprints - the DER SubjectPublicKeyInfo hashed with
  #     every available algorithm, colon-hex formatted
  #   type / public_data - RSA: size/modulus/exponent; ECC:
  #     curve/x/y/exponent_size; Ed25519/X25519/etc.: empty dict
  #   key_is_consistent - nil unless check_consistency: true (a sign/verify
  #     round trip is what the real module does; openssl cannot be asked
  #     for exactly that in one shot, and no role passes the flag)
  #   private_data - only with return_private_key_data: true (RSA
  #     p/q/exponent, DSA x, ECC multiplier), parsed the same way
  #
  # Big integers (RSA moduli, ECC coordinates) go out as decimal strings
  # when they do not fit Int64 - see X509CertInfo.json_int.
  class OpensslPrivatekeyInfoPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # The real module's argument_spec - no file-common args (no
    # add_file_common_args), no aliases.
    SPEC = {
      "path"                    => [] of String,
      "content"                 => [] of String,
      "passphrase"              => [] of String,
      "return_private_key_data" => [] of String,
      "check_consistency"       => [] of String,
      "select_crypto_backend"   => [] of String,
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
        unless File.readable?(path)
          res = failure("Error while reading private key file from disk: [Errno 2] No such file or directory: '#{path}'")
          res.extra["can_load_key"] = JSON::Any.new(false)
          res.extra["can_parse_key"] = JSON::Any.new(false)
          res.extra["key_is_consistent"] = JSON::Any.new(nil)
          return res
        end
        key_data = File.read(path)
      else
        key_data = content || ""
      end

      key_file = File.tempname("pkeyinfo")
      File.write(key_file, key_data)
      begin
        probe_key(key_file)
      ensure
        File.delete(key_file) if File.exists?(key_file)
      end
    end

    private def probe_key(key_file : String) : PluginResult
      args = ["pkey", "-in", key_file]
      args.concat(["-passin", "pass:#{@params["passphrase"]}"]) if @params["passphrase"]?

      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args + ["-noout"], output: stdout_io, error: err)
      unless status.success?
        res = failure(status_err_text(err))
        res.extra["can_load_key"] = JSON::Any.new(true)
        res.extra["can_parse_key"] = JSON::Any.new(false)
        res.extra["key_is_consistent"] = JSON::Any.new(nil)
        return res
      end

      pub_pem = openssl_out(args + ["-pubout"])
      spki_der = openssl_der(args + ["-pubout", "-outform", "DER"])
      text = openssl_out(args + ["-noout", "-text"])

      res = PluginResult.new(changed: false, failed: false, msg: "")
      res.extra["can_load_key"] = JSON::Any.new(true)
      res.extra["can_parse_key"] = JSON::Any.new(true)
      res.extra["key_is_consistent"] = JSON::Any.new(nil)
      res.extra["public_key"] = JSON::Any.new(pub_pem) if pub_pem
      res.extra["public_key_fingerprints"] = X509CertInfo.fingerprints_any(spki_der) if spki_der

      key_type, public_data, private_data = classify_key(text || "")
      res.extra["type"] = JSON::Any.new(key_type)
      res.extra["public_data"] = JSON::Any.new(public_data.to_h { |k, v| {k, v} })
      res.extra["private_data"] = JSON::Any.new(private_data.to_h { |k, v| {k, v} }) if true?(@params["return_private_key_data"]?)
      res
    end

    # Real AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required_one_of -> types -> choices -> mutually_exclusive ->
    # unsupported (deferred last). Types: return_private_key_data and
    # check_consistency are bool; the rest are str/path.
    private def validate_arguments : PluginResult?
      if @params["path"]?.nil? && @params["content"]?.nil?
        return failure("one of the following is required: path, content")
      end

      %w[return_private_key_data check_consistency].each do |param|
        if raw = @params[param]?
          return bool_type_error(param, raw) unless bool_convertible?(raw)
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

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.openssl_privatekey_info", unsupported, SPEC)
      end
      nil
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # Real Ansible wraps the underlying library error; its exact text
    # varies by cryptography version and failure mode. The constant part
    # is what a role can actually branch on: the module's own prefix.
    private def status_err_text(err : IO::Memory) : String
      "Could not load the private key (wrong passphrase?): #{err.to_s.strip.lines.first? || "unknown error"}"
    end

    private def openssl_out(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io)
      status.success? ? stdout_io.to_s : nil
    end

    private def openssl_der(args : Array(String)) : Bytes?
      stdout_io = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io)
      status.success? ? stdout_io.to_slice : nil
    end

    private def classify_key(text : String) : Tuple(String, Hash(String, JSON::Any), Hash(String, JSON::Any))
      private_data = {} of String => JSON::Any
      key_type, public_data = X509CertInfo.classify_public_key(text)
      case key_type
      when "RSA"
        # The private key text carries the RSA private components too
        # (openssl prints them as prime1/prime2/privateExponent).
        if p = X509CertInfo.labeled_hex_value(text, "prime1")
          private_data["p"] = p
        end
        if q = X509CertInfo.labeled_hex_value(text, "prime2")
          private_data["q"] = q
        end
        if d = X509CertInfo.labeled_hex_value(text, "privateExponent")
          private_data["exponent"] = d
        end
        return {"RSA", public_data, private_data}
      when "ECC"
        if d = X509CertInfo.labeled_hex_value(text, "priv:")
          private_data["multiplier"] = d
        end
        return {"ECC", public_data, private_data}
      else
        return {key_type, public_data, private_data}
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::OpensslPrivatekeyInfoPlugin.new(config)
plugin.run
