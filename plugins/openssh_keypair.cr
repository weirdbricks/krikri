#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # openssh_keypair plugin (community.crypto.openssh_keypair) - (re)
  # generates an OpenSSH private/public keypair via `ssh-keygen`. Ported
  # from the real module's `opensshbin` backend (the module's own
  # default backend whenever no `passphrase` is given) - the module's
  # `cryptography`-library backend is skipped since this codebase has
  # no Python runtime to lean on.
  #
  # Unlike the real module (which switches to a cryptography-only
  # backend the moment `passphrase` is set), this plugin always shells
  # to `ssh-keygen`, which itself supports `-N <passphrase>` directly -
  # same end result (an encrypted private key file), just via the CLI
  # instead of the `cryptography` library.
  #
  # Parameters: path (required), type (default rsa), size, state
  # (present/absent, default present), force, regenerate (never/fail/
  # partial_idempotence [default]/full_idempotence/always), comment,
  # passphrase, owner/group/mode, check_mode.
  class OpensshKeypairPlugin < BasePlugin
    VALID_TYPES = ["rsa", "dsa", "rsa1", "ecdsa", "ed25519"]

    def execute : PluginResult
      path = @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path") unless path

      path = expand_tilde(path)
      pub_path = "#{path}.pub"
      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      return remove(path, pub_path, check_mode) if state == "absent"

      type = @params["type"]? || "rsa"
      unless VALID_TYPES.includes?(type)
        return PluginResult.new(changed: false, failed: true, msg: "#{type} is not a valid value for key type")
      end

      size_result = resolve_size(type, @params["size"]?.try(&.to_i))
      return size_result if size_result.is_a?(PluginResult)
      size = size_result

      if path_err = validate_path(path)
        return path_err
      end

      ensure_present(path, pub_path, type, size, check_mode)
    end

    private def ensure_present(path : String, pub_path : String, type : String, size : Int32, check_mode : Bool) : PluginResult
      force = is_true?(@params["force"]?)
      regenerate = force ? "always" : (@params["regenerate"]? || "partial_idempotence")
      comment = @params["comment"]?
      passphrase = @params["passphrase"]? || ""

      info = File.exists?(path) ? key_info(path) : nil
      return unreadable_key_error(path) if regenerate == "never" && File.exists?(path) && info.nil?

      return generate_or_preview(path, pub_path, type, size, comment, passphrase, check_mode) if should_generate?(info, size, type, regenerate)

      changed = maybe_update_comment(path, pub_path, comment, passphrase, check_mode)
      changed = apply_attrs(path, pub_path) || changed
      report(path, pub_path, type, size, changed)
    end

    private def generate_or_preview(path : String, pub_path : String, type : String, size : Int32, comment : String?, passphrase : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: true, failed: false, msg: "Would generate SSH keypair at #{path} (check mode)", size: size, type: type, filename: path) if check_mode
      generate(path, pub_path, type, size, comment, passphrase)
    end

    private def unreadable_key_error(path : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Unable to read the key. The key is protected with a passphrase or broken. Will not proceed. To force regeneration, call the module with `regenerate` set to `full_idempotence` or `always`, or with `force=true`.")
    end

    private def validate_path(path : String) : PluginResult?
      base_dir = File.dirname(path)
      unless Dir.exists?(base_dir)
        return PluginResult.new(changed: false, failed: true, msg: "The directory '#{base_dir}' does not exist or the file is not a directory")
      end

      if File.directory?(path)
        return PluginResult.new(changed: false, failed: true, msg: "#{path} is a directory. Please specify a path to a file.")
      end

      nil
    end

    private def resolve_size(type : String, requested : Int32?) : Int32 | PluginResult
      case type
      when "rsa", "rsa1"
        size = requested || 4096
        return PluginResult.new(changed: false, failed: true, msg: "For RSA keys, the minimum size is 1024 bits and the default is 4096 bits.") if size < 1024
        size
      when "dsa"
        size = requested || 1024
        return PluginResult.new(changed: false, failed: true, msg: "DSA keys must be exactly 1024 bits as specified by FIPS 186-2.") if size != 1024
        size
      when "ecdsa"
        size = requested || 256
        return PluginResult.new(changed: false, failed: true, msg: "For ECDSA keys, size must be one of 256, 384 or 521 bits.") unless [256, 384, 521].includes?(size)
        size
      else # ed25519 - user size is ignored
        256
      end
    end

    private record KeyInfo, bits : Int32, comment : String

    # `ssh-keygen -l -f <path>` reads only the key's public portion
    # (embedded unencrypted even in a passphrase-protected private key
    # file), so it works without needing the passphrase.
    private def key_info(path : String) : KeyInfo?
      stdout = IO::Memory.new
      status = Process.run("ssh-keygen", ["-l", "-f", path], output: stdout, error: Process::Redirect::Close)
      return nil unless status.success?

      line = stdout.to_s.strip
      # "<bits> SHA256:... <comment> (TYPE)"
      parts = line.split(' ', 3)
      return nil if parts.size < 3
      bits = parts[0].to_i?
      return nil unless bits

      rest = parts[2]
      comment = rest.rchop(rest.split(' ').last).strip
      KeyInfo.new(bits, comment)
    end

    private def should_generate?(info : KeyInfo?, size : Int32, type : String, regenerate : String) : Bool
      return true if info.nil?
      return false if regenerate == "never"
      valid = info.bits == size

      case regenerate
      when "fail"
        false
      when "partial_idempotence", "full_idempotence"
        !valid
      else # always
        true
      end
    end

    private def generate(path : String, pub_path : String, type : String, size : Int32, comment : String?, passphrase : String) : PluginResult
      tmp = File.tempname("sshkey")
      tmp_pub = "#{tmp}.pub"
      File.delete(tmp) if File.exists?(tmp)

      args = ["-q", "-t", type, "-f", tmp, "-N", passphrase]
      args += ["-b", size.to_s] unless type == "ed25519"
      args += ["-C", comment] if comment

      err = IO::Memory.new
      status = Process.run("ssh-keygen", args, output: Process::Redirect::Close, error: err)
      unless status.success?
        File.delete(tmp) if File.exists?(tmp)
        File.delete(tmp_pub) if File.exists?(tmp_pub)
        return PluginResult.new(changed: false, failed: true, msg: "ssh-keygen failed: #{err}")
      end

      File.rename(tmp, path)
      File.rename(tmp_pub, pub_path)
      apply_attrs(path, pub_path)
      report(path, pub_path, type, size, true)
    end

    private def maybe_update_comment(path : String, pub_path : String, comment : String?, passphrase : String, check_mode : Bool) : Bool
      return false unless comment
      current = key_info(path)
      return false if current.nil? || current.comment == comment
      return true if check_mode

      status = Process.run("ssh-keygen", ["-q", "-c", "-C", comment, "-f", path, "-P", passphrase], output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.success?
    end

    private def apply_attrs(path : String, pub_path : String) : Bool
      before = File.exists?(path) ? File.info(path).permissions.value : nil
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      apply_owner_group_mode(pub_path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      after = File.exists?(path) ? File.info(path).permissions.value : nil
      before != after
    rescue
      false
    end

    private def report(path : String, pub_path : String, type : String, size : Int32, changed : Bool) : PluginResult
      pub_content = File.exists?(pub_path) ? File.read(pub_path).strip : ""
      fingerprint = ""
      stdout = IO::Memory.new
      if Process.run("ssh-keygen", ["-l", "-f", path], output: stdout, error: Process::Redirect::Close).success?
        parts = stdout.to_s.strip.split(' ')
        fingerprint = parts[1]? || ""
      end
      comment = pub_content.split(' ', 3)[2]? || ""

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "SSH keypair generated/updated at #{path}" : "SSH keypair already present at #{path}",
        size: size,
        type: type,
        filename: path,
        fingerprint: fingerprint,
        public_key: pub_content,
        comment: comment
      )
    end

    private def remove(path : String, pub_path : String, check_mode : Bool) : PluginResult
      exists = File.exists?(path) || File.exists?(pub_path)
      return PluginResult.new(changed: exists, failed: false, msg: exists ? "Would remove #{path}/#{pub_path} (check mode)" : "already absent") if check_mode
      return PluginResult.new(changed: false, failed: false, msg: "already absent") unless exists

      File.delete(path) if File.exists?(path)
      File.delete(pub_path) if File.exists?(pub_path)
      PluginResult.new(changed: true, failed: false, msg: "Removed #{path} and #{pub_path}")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::OpensshKeypairPlugin.new(config)
plugin.run
