#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # openssl_pkcs12 plugin (community.crypto.openssl_pkcs12) - bundles a
  # private key and its certificate into a PKCS#12 archive.
  #
  # `action: export` only, which is what the corpus uses
  # (robertdebock.openssl / buluma.openssl both export a `.p12` next to
  # the key and cert they just generated); `action: parse` fails with a
  # clear message rather than silently doing nothing.
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
    def execute : PluginResult
      path = @params["path"]?
      return failure("missing required arguments: path") unless path

      path = expand_tilde(path)
      state = @params["state"]? || "present"
      check_mode = true?(@params["check_mode"]?)
      action = @params["action"]? || "export"

      return remove(path, check_mode) if state == "absent"

      unless action == "export"
        return failure("The action '#{action}' is not supported by this implementation; only 'export' is.")
      end

      privatekey_path = @params["privatekey_path"]?.try { |value| expand_tilde(value) }
      certificate_path = @params["certificate_path"]?.try { |value| expand_tilde(value) }
      return failure("state is present but all of the following are missing: privatekey_path") unless privatekey_path
      return failure("The private key #{privatekey_path} does not exist") unless File.exists?(privatekey_path)
      if certificate_path && !File.exists?(certificate_path)
        return failure("The certificate #{certificate_path} does not exist")
      end

      base_dir = File.dirname(path)
      return failure("The directory #{base_dir} does not exist or the file is not a directory") unless Dir.exists?(base_dir)

      changed = true?(@params["force"]?) || !File.exists?(path) ||
                !matches?(path, privatekey_path, certificate_path)

      if changed && !check_mode
        backup_file = backup(path)
        if error = export(path, privatekey_path, certificate_path)
          return failure(error)
        end
        apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]? || "0400")
        return result(true, path, privatekey_path, backup_file)
      end

      return result(true, path, privatekey_path, nil) if changed

      attrs_changed = apply_attrs(path)
      result(attrs_changed, path, privatekey_path, nil)
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

    private def passphrase : String
      @params["passphrase"]? || ""
    end

    private def export(path : String, privatekey_path : String, certificate_path : String?) : String?
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
        if (other = other_certificates) && !other.empty?
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

    private def other_certificates : Array(String)
      raw = @params["other_certificates"]?
      return [] of String if raw.nil? || raw.empty?
      if parsed = (JSON.parse(raw).as_a? rescue nil)
        parsed.map { |v| expand_tilde(v.as_s? || v.to_s) }
      else
        raw.split(',').map { |v| expand_tilde(v.strip) }.reject(&.empty?)
      end
    end

    # --- idempotency -----------------------------------------------------

    private def matches?(path : String, privatekey_path : String, certificate_path : String?) : Bool
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

plugin = CrystalPlay::OpensslPkcs12Plugin.new(config)
plugin.run
