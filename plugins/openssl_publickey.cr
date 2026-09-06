#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/x509_cert_info"

module Krikri
  # openssl_publickey plugin (community.crypto.openssl_publickey) -
  # derives a public key from a private key and writes it to `path:`.
  #
  # Behavior matched against the real module (community.crypto 3.1.1):
  #
  #   * formats: PEM (default, SubjectPublicKeyInfo) and OpenSSH (the
  #     `ssh-keygen -y` single line, comment stripped)
  #   * idempotency: the desired public key is derived from the private
  #     key and compared against the file's current content (the real
  #     module re-serializes both sides canonically; a normalized text
  #     comparison here settles the same way)
  #   * state: absent removes the file (with backup)
  #   * result: privatekey (the private key path), filename, format,
  #     fingerprint (all algorithms, of the DER public key),
  #     backup_file, publickey (with return_content), diff before/after
  #     with the openssl_publickey_info-style info the real diff carries
  #
  # A passphrase-protected key works through both openssl and
  # ssh-keygen's own passphrase flags.
  class OpensslPublickeyPlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]?
      return failure("missing required arguments: path") unless path

      path = expand_tilde(path)
      state = @params["state"]? || "present"
      check_mode = true?(@params["check_mode"]?)

      return remove(path, check_mode) if state == "absent"

      privatekey_path = @params["privatekey_path"]?.try { |value| expand_tilde(value) }
      privatekey_content = @params["privatekey_content"]?
      if privatekey_path.nil? && privatekey_content.nil?
        return failure("state is present but any of the following are missing: privatekey_path, privatekey_content")
      end
      if privatekey_path && privatekey_content
        return failure("parameters are mutually exclusive: privatekey_path|privatekey_content")
      end
      if privatekey_path
        return failure("The private key #{privatekey_path} does not exist") unless File.exists?(privatekey_path)
      end

      base_dir = File.dirname(path)
      return failure("The directory #{base_dir} does not exist or the file is not a directory") unless Dir.exists?(base_dir)

      format = @params["format"]? || "PEM"
      return failure("value of format must be one of: OpenSSH, PEM, got: #{format}") unless ["OpenSSH", "PEM"].includes?(format)

      desired = derive(path, format, privatekey_path, privatekey_content)
      return failure("Unable to derive a public key from the private key (wrong passphrase?)") unless desired

      changed = true?(@params["force"]?) || !File.exists?(path) || !same_key(File.read(path), desired, format)

      if changed && check_mode
        return result(true, path, privatekey_path, format, nil, desired)
      end

      if changed
        backup_file = backup(path)
        File.write(path, desired)
        # Public key material - 0644-by-umask like the real module's
        # write_file default, not the 0600 a private key gets.
        File.chmod(path, 0o666 & ~current_umask) unless @params["mode"]?
        apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
        return result(true, path, privatekey_path, format, backup_file, desired)
      end

      attrs_changed = apply_attrs(path)
      result(attrs_changed, path, privatekey_path, format, nil, desired)
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

    private def derive(path : String, format : String, privatekey_path : String?, privatekey_content : String?) : String?
      # ssh-keygen needs the key on disk; a content-sourced key is
      # staged to a temp file first (both formats read from a file).
      key_file = privatekey_path
      if key_file.nil?
        staged = stage(privatekey_content) if privatekey_content
        return nil unless staged
        key_file = staged
      end

      if format == "OpenSSH"
        args = ["-y", "-f", key_file]
        args.concat(["-P", @params["privatekey_passphrase"]]) if @params["privatekey_passphrase"]?
        stdout_io = IO::Memory.new
        err = IO::Memory.new
        status = Process.run("ssh-keygen", args, output: stdout_io, error: err)
        return nil unless status.success?
        stdout_io.to_s.strip + "\n"
      else
        args = ["pkey", "-in", key_file, "-pubout"]
        args.concat(["-passin", "pass:#{@params["privatekey_passphrase"]}"]) if @params["privatekey_passphrase"]?
        stdout_io = IO::Memory.new
        status = Process.run("openssl", args, output: stdout_io)
        status.success? ? stdout_io.to_s : nil
      end
    ensure
      cleanup_staged
    end

    @staged = [] of String

    private def stage(content : String) : String?
      tmp = File.tempname("pubkeygen")
      File.write(tmp, content)
      @staged << tmp
      tmp
    end

    private def cleanup_staged
      @staged.each do |tmp|
        File.delete(tmp) if File.exists?(tmp)
      end
      @staged.clear
    end

    # Both sides are canonicalized line-by-line, so a key stored with
    # different line endings or trailing whitespace still compares
    # equal to the freshly derived one.
    private def same_key(existing : String, desired : String, format : String) : Bool
      normalize(existing) == normalize(desired)
    end

    private def normalize(text : String) : String
      text.lines.map(&.strip).reject(&.empty?).join("\n")
    end

    private def current_umask : UInt32
      mask = LibC.umask(0o022_u32)
      LibC.umask(mask)
      mask.to_u32
    end

    private def apply_attrs(path : String) : Bool
      return false unless File.exists?(path)
      before = File.info(path).permissions.value
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      File.info(path).permissions.value != before
    rescue
      false
    end

    private def backup(path : String) : String?
      return nil unless true?(@params["backup"]?)
      return nil unless File.exists?(path)
      dest = "#{path}.#{Process.pid}.#{Time.local.to_s("%Y-%m-%d@%H:%M:%S")}~"
      File.copy(path, dest)
      dest
    end

    private def result(changed : Bool, path : String, privatekey_path : String?,
                       format : String, backup_file : String?, desired : String?) : PluginResult
      res = PluginResult.new(changed: changed, failed: false, msg: "")
      res.extra["privatekey"] = JSON::Any.new(privatekey_path) if privatekey_path
      res.extra["filename"] = JSON::Any.new(path)
      res.extra["format"] = JSON::Any.new(format)
      res.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file
      if spki_der = spki_der_of(desired)
        res.extra["fingerprint"] = X509CertInfo.fingerprints_any(spki_der)
      end
      if true?(@params["return_content"]?)
        content = if changed
                    desired
                  elsif File.exists?(path)
                    File.read(path)
                  end
        res.extra["publickey"] = JSON::Any.new(content) if content
      end
      res
    end

    private def spki_der_of(pem_or_ssh : String?) : Bytes?
      return nil unless pem_or_ssh
      tmp = File.tempname("pubkeyder")
      File.write(tmp, pem_or_ssh)
      stdout_io = IO::Memory.new
      status = Process.run("openssl", ["pkey", "-pubin", "-in", tmp, "-outform", "DER"], output: stdout_io)
      status.success? ? stdout_io.to_slice : nil
    ensure
      File.delete(tmp) if tmp && File.exists?(tmp)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::OpensslPublickeyPlugin.new(config)
plugin.run
