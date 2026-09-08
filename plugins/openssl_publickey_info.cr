#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/x509_cert_info"

module Krikri
  # openssl_publickey_info plugin
  # (community.crypto.openssl_publickey_info) - loads a public key and
  # reports its facts. Read-only: no path is written, check_mode changes
  # nothing.
  #
  # Result shape matched against the real module (community.crypto
  # 3.1.1, publickey_info.py's get_info):
  #
  #   fingerprints - the DER SubjectPublicKeyInfo hashed with every
  #     available algorithm, colon-hex formatted (the real module names
  #     this field `fingerprints`, NOT `public_key_fingerprints` as the
  #     csr_info/certificate_info variants do)
  #   type - RSA / DSA / ECC / Ed25519 / X25519 / Ed448 / X448, or
  #     "unknown (...)"
  #   public_data - RSA: size/modulus/exponent; ECC:
  #     curve/x/y/exponent_size; Ed*/X*: empty dict; DSA: size only
  #
  # On failure the real module carries can_load_key/can_parse_key/
  # key_is_consistent in the failure result (all three false/None for a
  # read or parse error - the module only ever reports consistency for
  # private keys, never for this one).
  #
  # Big integers go out as decimal strings when they do not fit Int64 -
  # see X509CertInfo.json_int.
  class OpensslPublickeyInfoPlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]?.try { |value| expand_tilde(value) }
      content = @params["content"]?

      if path.nil? == content.nil?
        return failure("One of path or content must be specified, but not both")
      end

      if path
        unless File.readable?(path)
          return failure("Error while reading public key file from disk: [Errno 2] No such file or directory: '#{path}'")
        end
        key_data = File.read(path)
      else
        key_data = content || ""
      end

      key_file = File.tempname("pubkeyinfo")
      File.write(key_file, key_data)
      begin
        # the real backend's load_publickey accepts a bare public key
        # (PEM or DER); `openssl pkey -pubin` is the CLI equivalent.
        stdout_io = IO::Memory.new
        err = IO::Memory.new
        status = Process.run("openssl", ["pkey", "-pubin", "-in", key_file, "-noout"], output: stdout_io, error: err)
        unless status.success?
          return failure("Unable to parse the public key")
        end

        text = openssl_out(["pkey", "-pubin", "-in", key_file, "-noout", "-text"])
        spki_der = openssl_der(["pkey", "-pubin", "-in", key_file, "-outform", "DER"])

        res = PluginResult.new(changed: false, failed: false, msg: "")
        # the real module's result dict initializes these three BEFORE
        # get_info ever runs, so they appear (false/false/None) even on
        # SUCCESS - only a private key can ever be consistency-checked
        res.extra["can_load_key"] = JSON::Any.new(false)
        res.extra["can_parse_key"] = JSON::Any.new(false)
        res.extra["key_is_consistent"] = JSON::Any.new(nil)
        res.extra["fingerprints"] = X509CertInfo.fingerprints_any(spki_der) if spki_der

        key_type, key_public_data = X509CertInfo.classify_public_key(text || "")
        res.extra["type"] = JSON::Any.new(key_type)
        res.extra["public_data"] = JSON::Any.new(key_public_data.to_h { |k, v| {k, v} })
        res
      ensure
        File.delete(key_file) if File.exists?(key_file)
      end
    end

    private def failure(msg : String) : PluginResult
      res = PluginResult.new(changed: false, failed: true, msg: msg)
      res.extra["can_load_key"] = JSON::Any.new(false)
      res.extra["can_parse_key"] = JSON::Any.new(false)
      res.extra["key_is_consistent"] = JSON::Any.new(nil)
      res
    end

    private def openssl_out(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      status.success? ? stdout_io.to_s : nil
    end

    private def openssl_der(args : Array(String)) : Bytes?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      status.success? ? stdout_io.to_slice : nil
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::OpensslPublickeyInfoPlugin.new(config)
plugin.run
