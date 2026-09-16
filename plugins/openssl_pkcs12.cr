#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

module Krikri
  # openssl_pkcs12 plugin (community.crypto.openssl_pkcs12) - bundles a
  # private key and its certificate into a PKCS#12 archive (`action:
  # export`), and converts one back into a PEM bundle (`action: parse`).
  #
  # Export is what the corpus uses (robertdebock.openssl / buluma.openssl
  # both export a `.p12` next to the key and cert they just generated).
  # Parse requires `src:` (the archive to read) and writes the private
  # key followed by the certificates as PEM to `path:` - the real
  # module's parse is a converter, not an info-only read.
  #
  # Differentialed against the real module (community.crypto 3.1.1):
  #
  #   * the archive is written 0400 unless `mode:` says otherwise - the
  #     tightest default of any module in this family
  #   * `mode`, `filename` and `privatekey_path` are the returned keys
  #   * changing the friendly name, the key or the certificate rewrites
  #     the archive; an unchanged export is a no-op
  #
  # Idempotency reads the existing archive back with the same
  # passphrase and compares the key, the certificate and the friendly
  # name against the sources - a PKCS#12 file is salted, so two exports
  # of identical inputs never produce identical bytes and a file
  # comparison would rewrite it on every run.
  class OpensslPkcs12Plugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # The real module's argument_spec (declaration order) plus the
    # file-common args its add_file_common_args=True injects (the only
    # alias is attributes->attr; friendly_name's alias is on the module
    # key below).
    SPEC = {
      "action"                       => [] of String,
      "other_certificates"           => [] of String,
      "other_certificates_parse_all" => [] of String,
      "other_certificates_content"   => [] of String,
      "certificate_path"             => [] of String,
      "certificate_content"          => [] of String,
      "force"                        => [] of String,
      "friendly_name"                => ["name"],
      "encryption_level"             => [] of String,
      "iter_size"                    => [] of String,
      "maciter_size"                 => [] of String,
      "passphrase"                   => [] of String,
      "path"                         => [] of String,
      "privatekey_passphrase"        => [] of String,
      "privatekey_path"              => [] of String,
      "privatekey_content"           => [] of String,
      "state"                        => [] of String,
      "src"                          => [] of String,
      "backup"                       => [] of String,
      "return_content"               => [] of String,
      "select_crypto_backend"        => [] of String,
      "mode"                         => [] of String,
      "owner"                        => [] of String,
      "group"                        => [] of String,
      "seuser"                       => [] of String,
      "serole"                       => [] of String,
      "selevel"                      => [] of String,
      "setype"                       => [] of String,
      "attributes"                   => ["attr"],
      "unsafe_writes"                => [] of String,
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
        action = @params["action"]? || "export"

        return remove(path, check_mode) if state == "absent"

        if action == "parse"
          src = @params["src"]?.try { |value| expand_tilde(value) }
          return failure("action is parse but all of the following are missing: src") unless src
          return failure("The PKCS#12 file #{src} does not exist") unless File.exists?(src)
          return parse_action(path, src, check_mode)
        end

        privatekey_path = @params["privatekey_path"]?.try { |value| expand_tilde(value) }
        certificate_path = @params["certificate_path"]?.try { |value| expand_tilde(value) }
        if privatekey_path.nil? && (content = @params["privatekey_content"]?)
          privatekey_path = write_temp_content(temp_files, content)
        end
        if certificate_path.nil? && (content = @params["certificate_content"]?)
          certificate_path = write_temp_content(temp_files, content)
        end
        return failure("state is present but all of the following are missing: privatekey_path") unless privatekey_path
        return failure("The private key #{privatekey_path} does not exist") unless File.exists?(privatekey_path)
        if error = validate_rest(path, certificate_path)
          return error
        end

        # The real module serializes the archive through the
        # cryptography library: in check mode via the unconditional
        # dump() (a key/cert mismatch fails there before anything
        # else), on a write via generate_bytes() after its
        # friendly-name guard. An up-to-date archive without force
        # reaches neither.
        changed = true?(@params["force"]?) || !File.exists?(path) ||
                  !matches?(path, privatekey_path.not_nil!, certificate_path, temp_files)

        if certificate_path && (check_mode || changed) &&
           !key_matches_cert?(privatekey_path.not_nil!, certificate_path)
          return failure("Failed to create PKCS12 (does the key match the certificate?)")
        end

        if changed && check_mode
          return result(true, path, privatekey_path, nil)
        end

        if changed
          # Module-level policy (community.crypto 3.x): an export write
          # always carries a friendly name.
          friendly_name = @params["friendly_name"]?
          return failure("Friendly_name is required") if friendly_name.nil? || friendly_name.empty?

          return write_export(path, privatekey_path.not_nil!, certificate_path, temp_files)
        end

        attrs_changed = apply_attrs(path)
        result(attrs_changed, path, privatekey_path, nil)
      ensure
        temp_files.each { |file| File.delete(file) rescue nil }
      end
    end

    # other_certificates_content entries are PEM texts - materialized to
    # temp files so `openssl pkcs12 -certfile` can consume them like the
    # path-based variant.
    private def write_temp_content(temp_files : Array(String), content : String) : String
      file = File.tempname("pkcs12-content")
      File.write(file, content)
      temp_files << file
      file
    end

    private def other_certificates(temp_files : Array(String)) : Array(String)
      if (content_list = @params["other_certificates_content"]?) && !content_list.empty?
        entries = parse_list(content_list)
        return entries.map { |pem| write_temp_content(temp_files, pem) }
      end
      raw = @params["other_certificates"]?
      return [] of String if raw.nil? || raw.empty?
      parse_list(raw).map { |path| expand_tilde(path) }
    end

    # check_type_list semantics (a plain string is comma-split, no JSON
    # probing).
    private def parse_list(raw : String) : Array(String)
      case value = (JSON.parse(raw) rescue nil).try(&.raw)
      when Array
        value.map { |v| v.as_s? ? v.as_s : v.to_s }
      when String
        value.split(",").map(&.strip).reject(&.empty?)
      when Nil
        raw.split(",").map(&.strip).reject(&.empty?)
      else
        [value.to_s]
      end
    end

    private def validate_rest(path : String, certificate_path : String?) : PluginResult?
      if certificate_path && !File.exists?(certificate_path)
        return failure("The certificate #{certificate_path} does not exist")
      end

      base_dir = File.dirname(path)
      return failure("The directory #{base_dir} does not exist or the file is not a directory") unless Dir.exists?(base_dir)
      nil
    end

    private def key_matches_cert?(privatekey_path : String, certificate_path : String) : Bool
      key_pub = openssl_out(["pkey", "-in", privatekey_path, "-pubout"])
      cert_pub = openssl_out(["x509", "-in", certificate_path, "-pubkey", "-noout"])
      return false unless key_pub && cert_pub
      normalize_pem(key_pub) == normalize_pem(cert_pub)
    end

    private def openssl_out(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      status.success? ? stdout_io.to_s : nil
    end

    # action: parse - read the archive from `src`, write its private key
    # followed by its certificates as PEM to `path` (the real module's
    # parse is a converter, not an info-only read: it produces a file).
    # Idempotency compares the desired bundle against the file's current
    # content PEM-normalized (the real module compares its own
    # re-serialized PEM dump against the file's bytes, so both engines
    # settle on the same second-run "ok" and the same src-change rewrite).
    private def parse_action(path : String, src : String, check_mode : Bool) : PluginResult
      base_dir = File.dirname(path)
      return failure("The directory #{base_dir} does not exist or the file is not a directory") unless Dir.exists?(base_dir)

      desired = key_first_bundle(dump_pkcs12(src))
      return failure("openssl pkcs12 failed: unable to read #{src} (wrong passphrase?)") unless desired

      changed = true?(@params["force"]?) || !File.exists?(path) ||
                normalize_pem(File.read(path)) != normalize_pem(desired)

      return result_parse(true, path, src) if changed && check_mode

      if changed && !check_mode
        backup_file = backup(path)
        File.write(path, desired)
        apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
        return result_parse(true, path, src, backup_file)
      end

      attrs_changed = parse_attrs(path)
      result_parse(attrs_changed, path, src)
    end

    # The real module's parse concatenates [privatekey, certificate,
    # other certificates] in that order; openssl's own dump puts the
    # certificates first - so the blocks are reordered here, and the
    # same ordering applies on the idempotency comparison (both sides
    # of it go through this).
    private def key_first_bundle(dump : String?) : String?
      return nil unless dump
      blocks = [] of Tuple(Bool, String)
      scanner = dump
      while start = scanner.index("-----BEGIN ")
        stop = scanner.index("-----END ", start)
        break unless stop
        line_end = scanner.index('\n', stop)
        block = scanner[start...(line_end || scanner.size)]
        blocks << {block.includes?("KEY"), block}
        scanner = scanner[(line_end || scanner.size)..]
      end
      return nil if blocks.empty?
      # Each block is newline-terminated in the real module's output;
      # extract_block cuts before the '\n', so re-join with separators
      # and a trailing newline.
      blocks.sort_by { |is_key, _| is_key ? 0 : 1 }.map { |_, block| block + "\n" }.join
    end

    private def result_parse(changed : Bool, path : String, src : String, backup_file : String? = nil) : PluginResult
      res = PluginResult.new(changed: changed, failed: false, msg: "")
      res.extra["filename"] = JSON::Any.new(path)
      res.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      res
    end

    # Unlike export (whose archive is 0400 by default), parse writes a
    # plain PEM bundle with the ordinary file-common default - no forced
    # mode unless one was asked for.
    private def parse_attrs(path : String) : Bool
      return false unless File.exists?(path)
      before = File.info(path).permissions.value
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      File.info(path).permissions.value != before
    rescue
      false
    end

    private def write_export(path : String, privatekey_path : String, certificate_path : String?, temp_files : Array(String)) : PluginResult
      backup_file = backup(path)
      if error = export(path, privatekey_path, certificate_path, temp_files)
        return failure(error)
      end
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]? || "0400")
      result(true, path, privatekey_path, backup_file)
    end

    private def failure(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # Real AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required -> types (spec declaration order) -> choices -> required_if
    # -> mutually_exclusive -> unsupported (deferred last).
    private def validate_arguments : PluginResult?
      return missing_required_error(["path"]) unless @params["path"]?

      %w[iter_size maciter_size].each do |param|
        if raw = @params[param]?
          return int_type_error(param, raw) unless raw.to_i32?
        end
      end
      %w[other_certificates_parse_all force backup return_content unsafe_writes].each do |param|
        if raw = @params[param]?
          return bool_type_error(param, raw) unless bool_convertible?(raw)
        end
      end

      {"action"                => %w[export parse],
       "encryption_level"      => %w[auto compatibility2022],
       "state"                 => %w[absent present],
       "select_crypto_backend" => %w[auto cryptography]}.each do |param, allowed|
        if value = @params[param]?
          unless allowed.includes?(value)
            return choices_error(param, allowed, value)
          end
        end
      end

      if (@params["action"]? || "export") == "parse" && !@params["src"]?
        return failure("action is parse but all of the following are missing: src")
      end

      [%w[privatekey_path privatekey_content], %w[certificate_path certificate_content],
       %w[other_certificates other_certificates_content]].each do |pair|
        if pair.all? { |param| @params[param]? }
          return failure("parameters are mutually exclusive: #{pair.join("|")}")
        end
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.openssl_pkcs12", unsupported, SPEC)
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

    private def passphrase : String
      @params["passphrase"]? || ""
    end

    private def export(path : String, privatekey_path : String, certificate_path : String?, temp_files : Array(String) = [] of String) : String?
      tmp = File.tempname("pkcs12", dir: File.dirname(path))
      begin
        File.write(tmp, "")
        File.chmod(tmp, 0o600)

        args = ["pkcs12", "-export", "-out", tmp, "-inkey", privatekey_path,
                "-passout", "pass:#{passphrase}"]
        args.concat(["-in", certificate_path]) if certificate_path
        if (name = @params["friendly_name"]?) && !name.empty?
          args.concat(["-name", name])
        end
        if (other = other_certificates(temp_files)) && !other.empty?
          other.each { |certificate| args.concat(["-certfile", certificate]) }
        end
        if (key_passphrase = @params["privatekey_passphrase"]?) && !key_passphrase.empty?
          args.concat(["-passin", "pass:#{key_passphrase}"])
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

    # --- idempotency -----------------------------------------------------

    private def matches?(path : String, privatekey_path : String, certificate_path : String?, temp_files : Array(String) = [] of String) : Bool
      dump = dump_pkcs12(path)
      return false unless dump

      if (name = @params["friendly_name"]?) && !name.empty?
        return false unless dump.includes?("friendlyName: #{name}")
      end

      key_in_archive = extract_block(dump, "PRIVATE KEY")
      return false unless key_in_archive
      key_on_disk = normalized_key(privatekey_path)
      return false unless key_on_disk && normalize_pem(key_in_archive) == key_on_disk

      if certificate_path
        certificate_in_archive = extract_block(dump, "CERTIFICATE")
        return false unless certificate_in_archive
        return false unless normalize_pem(certificate_in_archive) == normalize_pem(File.read(certificate_path))
      end

      if (other = other_certificates(temp_files)) && !other.empty?
        archive_certs = dump.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map(&.[0])
        return false unless archive_certs.size >= other.size
      end

      true
    rescue
      false
    end

    # `-nodes` dumps the key unencrypted, so the archive's copy can be
    # compared against the source key regardless of how either side is
    # encrypted at rest.
    private def dump_pkcs12(path : String) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl",
        ["pkcs12", "-in", path, "-nodes", "-passin", "pass:#{passphrase}"],
        output: stdout_io, error: err)
      status.success? ? stdout_io.to_s : nil
    end

    # The archive always holds the key in PKCS#8 form, while the source
    # file may be PKCS#1 - so both sides are canonicalized through
    # `openssl pkey` before comparison rather than compared as text.
    private def normalized_key(path : String) : String?
      args = ["pkey", "-in", path]
      if (key_passphrase = @params["privatekey_passphrase"]?) && !key_passphrase.empty?
        args.concat(["-passin", "pass:#{key_passphrase}"])
      end
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      return nil unless status.success?
      normalize_pem(stdout_io.to_s)
    end

    private def normalize_pem(text : String) : String
      text.lines.map(&.strip).reject(&.empty?).join("\n")
    end

    private def extract_block(text : String, kind : String) : String?
      start_marker = text.index("-----BEGIN #{kind}-----")
      # A PKCS#8 key in the dump is "-----BEGIN PRIVATE KEY-----", but an
      # archive written elsewhere may hold an "ENCRYPTED PRIVATE KEY" or
      # an "RSA PRIVATE KEY" block instead.
      start_marker ||= text.index(/-----BEGIN [A-Z0-9 ]*#{kind}-----/)
      return nil unless start_marker

      end_marker = text.index("-----END", start_marker)
      return nil unless end_marker
      line_end = text.index('\n', end_marker) || text.size
      text[start_marker...line_end]
    end

    # --- reporting --------------------------------------------------------

    private def result(changed : Bool, path : String, privatekey_path : String,
                       backup_file : String?) : PluginResult
      res = PluginResult.new(changed: changed, failed: false, msg: "")
      res.extra["filename"] = JSON::Any.new(path)
      res.extra["privatekey_path"] = JSON::Any.new(privatekey_path)
      res.extra["mode"] = JSON::Any.new(@params["mode"]? || "0400")
      res.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      if true?(@params["return_content"]?) && File.exists?(path)
        res.extra["pkcs12"] = JSON::Any.new(Base64.strict_encode(File.read(path)))
      end
      res
    end

    private def apply_attrs(path : String) : Bool
      return false unless File.exists?(path)
      before = File.info(path).permissions.value
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]? || "0400")
      File.info(path).permissions.value != before
    rescue
      false
    end

    private def run_openssl(args : Array(String)) : String?
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", args, output: stdout_io, error: err)
      return nil if status.success?
      "openssl pkcs12 failed: #{err.to_s.strip}"
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

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::OpensslPkcs12Plugin.new(config)
plugin.run
