#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/crypto_time_spec"
require "../src/krikri/plugin_helpers/x509_cert_info"

module Krikri
  # x509_certificate_info plugin (community.crypto.x509_certificate_info)
  # - reads a certificate and reports its facts. Read-only: no path is
  # written, no idempotency to maintain, check_mode changes nothing.
  #
  # Backed by the `openssl` CLI through the shared X509CertInfo helper
  # (see its header for the field-by-field provenance). Params:
  # path (a PEM or DER certificate file) or content (PEM text), exactly
  # one of the two, matching the Ansible module's required_one_of plus
  # mutually_exclusive pair.
  #
  # Integers wider than Int64 go out as JSON numbers too (sentinel-
  # carried through the controller) - see the helper's json_int.
  class X509CertificateInfoPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Live-verified against ansible-core 2.19.11 (community.crypto
    # 3.1.1) via `{{ r | to_json }}` dump on a self-signed cert: absent
    # extension/detail keys are simply skipped by the reorder, and real
    # registers failed before changed. failed_flag puts failed=false on
    # the wire in its own slot; without it the executor's backfill would
    # append it after changed.
    SUCCESS_KEY_ORDER = %w[
      signature_algorithm subject subject_ordered issuer issuer_ordered
      version key_usage key_usage_critical extended_key_usage
      extended_key_usage_critical basic_constraints basic_constraints_critical
      ocsp_must_staple ocsp_must_staple_critical subject_alt_name
      subject_alt_name_critical not_before not_after expired public_key
      public_key_type public_key_data public_key_fingerprints fingerprints
      subject_key_identifier authority_key_identifier authority_cert_issuer
      authority_cert_serial_number serial_number extensions_by_oid ocsp_uri
      issuer_uri valid_at failed changed warnings
    ]

    # The Ansible module's argument_spec - no file-common args (no
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

      raw = content || ""
      if path
        read = read_certificate_file(path)
        return read unless read.is_a?(String)
        raw = read
      end

      # The Ansible module resolves valid_at AFTER reading the file and
      # selecting the backend but BEFORE parsing the certificate, so an
      # invalid spec fails ahead of an unparseable one. Per key, in dict
      # order (the module mutates module.params["valid_at"] in place, and
      # every echo - success or plain-fail_json failure - shows the keys
      # resolved so far): a non-string element fails with fail_json's
      # plain msg; an invalid spec raises out of main() uncaught - the
      # unhandled-exception shape ("Task failed: Module failed: ...",
      # whose module output carries no invocation at all).
      failure, parsed, resolved = resolve_valid_at
      return failure if failure

      cert_pem = extract_pem(raw)
      if cert_pem.nil? && !raw.includes?("-----BEGIN CERTIFICATE-----")
        cert_pem = convert_der(raw, path)
      end
      return failure("Unable to parse the certificate") unless cert_pem

      info = X509CertInfo.parse(cert_pem)
      return failure("Unable to parse the certificate") unless info

      res = PluginResult.new(changed: false, failed: false, msg: "", failed_flag: true, key_order: SUCCESS_KEY_ORDER)
      info.each do |key, value|
        res.extra[key] = value
      end
      res.extra["valid_at"] = valid_at_result(info, resolved)
      if parsed
        # The echoed invocation.module_args ride the controller's argspec
        # reconstruction (attach_invocation); this private marker hands it
        # the resolved datetimes the booleans above were answered with,
        # stripped again before register.
        res.extra["_ansible_invocation_module_args"] = JSON::Any.new({"valid_at" => valid_at_echo(parsed, resolved)} of String => JSON::Any)
      end
      res
    end

    # The Ansible module always sets result["valid_at"] ({} when the
    # option is absent), then answers one boolean per probe:
    # not_before <= point <= not_after, where each probe value went
    # through _time.py get_relative_time_option first - a relative
    # +/- sshd_config(5) spec resolved against UTC now, or one of four
    # absolute shapes (the same set crypto_time_spec_valid? accepts).
    private def valid_at_result(info : Hash(String, JSON::Any), resolved : Hash(String, Time)) : JSON::Any
      probes = {} of String => JSON::Any
      unless resolved.empty?
        not_before = asn1_time(info["not_before"]?)
        not_after = asn1_time(info["not_after"]?)
        resolved.each do |key, point|
          if (nb = not_before) && (na = not_after)
            probes[key] = JSON::Any.new(nb <= point <= na)
          else
            probes[key] = JSON::Any.new(false)
          end
        end
      end
      JSON::Any.new(probes)
    end

    # The module's per-key valid_at loop, verbatim order: for each key
    # the type check (plain fail_json - invocation still echoes the
    # dict with every earlier key already resolved) then the resolution
    # (an invalid spec raises out of main() uncaught). Each key's "now"
    # is taken fresh, the way real's per-key get_relative_time_option
    # call does - two keys resolve a couple of microseconds apart.
    # Returns the failure result (nil on success), the raw parsed dict
    # and the resolved points.
    private def resolve_valid_at : {PluginResult?, Hash(String, JSON::Any)?, Hash(String, Time)}
      resolved = {} of String => Time
      raw = @params["valid_at"]?
      return {nil, nil, resolved} unless raw
      parsed = (JSON.parse(raw).as_h? rescue nil)
      return {nil, nil, resolved} unless parsed
      parsed.each do |key, entry|
        unless entry.as_s?
          result = failure_hash_type(key, entry)
          # fail_json echoes module.params - the earlier keys already
          # mutated in place, this one (and the never-reached ones) raw.
          result.extra["_ansible_invocation_module_args"] = JSON::Any.new({"valid_at" => valid_at_echo(parsed, resolved)} of String => JSON::Any)
          return {result, parsed, resolved}
        end
        spec = entry.as_s
        point = CryptoTimeSpec.resolve(spec)
        unless point
          # No echo marker here: the crash output carries no invocation.
          return {module_crash_result(invalid_spec_detail(spec, key)), parsed, resolved}
        end
        resolved[key] = point
      end
      {nil, parsed, resolved}
    end

    # The echoed valid_at: every resolved key serialized the way real's
    # module JSON encoder prints the mutated datetime (CryptoTimeSpec.echo),
    # keyed in the task's own dict order; keys not resolved yet (a
    # fail_json failure's not-yet-reached tail) echo their raw value.
    private def valid_at_echo(parsed : Hash(String, JSON::Any), resolved : Hash(String, Time)) : JSON::Any
      with_timezone = CryptoTimeSpec.with_timezone?
      echo = JSON::Any.new({} of String => JSON::Any)
      parsed.each do |key, entry|
        point = resolved[key]?
        echo.as_h[key] = point ? JSON::Any.new(CryptoTimeSpec.echo(point, with_timezone)) : entry
      end
      echo
    end

    # The two invalid-spec wordings differ by one word: the relative path
    # raises 'The timespec "..." is invalid' (convert_relative_to_datetime
    # returned nil - a lone "+" lands here too), the absolute path
    # 'The time spec "..." is invalid' (no format matched).
    private def invalid_spec_detail(spec : String, key : String) : String
      if spec.starts_with?('+') || spec.starts_with?('-')
        %(The timespec "#{spec}" for valid_at.#{key} is invalid)
      else
        %(The time spec "#{spec}" for valid_at.#{key} is invalid)
      end
    end

    # Real opens the file bare and fail_jsons with str(OSError) once the
    # open/read raises - there is no readability precheck in
    # community.crypto's module - so a missing path surfaces as
    # "[Errno 2] No such file or directory: '30'", not a probe verdict.
    private def read_certificate_file(path : String) : String | PluginResult
      # Python's open() itself raises EISDIR (with the filename attached)
      # before any read happens; Crystal only trips EISDIR on the read,
      # so classify the directory case up front.
      return failure(read_cert_oserror(21, "Is a directory", path)) if File.directory?(path)
      begin
        File.read(path)
      rescue ex : File::Error
        errno = ex.os_error
        if errno
          failure(read_cert_oserror(errno.value, errno.message, path))
        else
          failure(read_cert_oserror(*fallback_oserror(path), path))
        end
      end
    end

    # Python's str(OSError) shape: "[Errno N] <strerror>: '<path>'" when
    # the exception carries a filename.
    private def read_cert_oserror(code : Int32 | UInt16 | UInt32, strerror : String, path : String) : String
      "Error while reading certificate file from disk: [Errno #{code}] #{strerror}: '#{path}'"
    end

    # The same exists/directory classification url_preflight uses, for a
    # File::Error that lost its errno.
    private def fallback_oserror(path : String) : {Int32, String}
      return {21, "Is a directory"} if File.directory?(path)
      return {13, "Permission denied"} if File.exists?(path)
      {2, "No such file or directory"}
    end

    # fail_json's own msg - no "Task failed: Module failed:" wrapper, the
    # module output carries invocation (live-verified vs 2.19.11).
    private def failure_hash_type(key : String, entry : JSON::Any) : PluginResult
      failure("The value for valid_at.#{key} must be of type string (got #{CryptoTimeSpec.python_type_name(entry)})")
    end

    # An unhandled module exception (the valid_at loop sits outside the
    # module's try block): real renders it as "Task failed: Module
    # failed: <detail>" with base_plugin's "exception": "(traceback
    # unavailable)" bookkeeping - same shape assemble.cr/mount.cr use
    # for their module crashes.
    private def module_crash_result(detail : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
    end

    private def asn1_time(value : JSON::Any?) : Time?
      return nil unless (raw = value.try(&.as_s?))
      Time.parse_utc(raw, "%Y%m%d%H%M%SZ")
    rescue Time::Format::Error
      nil
    end

    # AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required_one_of -> types -> choices -> mutually_exclusive ->
    # unsupported (deferred last). Types are str/path/dict here; the
    # dict-typed valid_at's elements each must be a string (a check the
    # module's own per-key loop runs, not AnsibleModule's spec pass).
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
    # bundle); the Ansible module reads the first certificate.
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
