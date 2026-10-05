#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/python_lib_gate"

module Krikri
  # openssh_keypair plugin (community.crypto.openssh_keypair) - (re)
  # generates an OpenSSH private/public keypair via `ssh-keygen`. Ported
  # from the Ansible module's `opensshbin` backend (the module's own
  # default backend whenever no `passphrase` is given) - the module's
  # `cryptography`-library backend is skipped since this codebase has
  # no Python runtime to lean on.
  #
  # Unlike the Ansible module (which switches to a cryptography-only
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
    include PluginHelpers::AnsibleArgValidation

    # The Ansible module's argument_spec plus the file-common args its
    # add_file_common_args=True injects (ansible-core 2.14's
    # Live-verified against ansible-core 2.19.11 (community.crypto
    # 3.1.1) via `{{ r | to_json }}` dumps, identical on changed,
    # unchanged, check-mode and state=absent runs (the backend's _result
    # dict always carries all six keys, then the controller adds
    # changed). krikri's msg stays unlisted and trails, per the get_url
    # convention for keys Ansible doesn't emit.
    SUCCESS_KEY_ORDER = %w[
      size type filename fingerprint public_key comment changed ansible_facts
      failed warnings
    ]

    # FILE_COMMON_ARGUMENTS: the only alias is attributes->attr).
    SPEC = {
      "state"              => [] of String,
      "size"               => [] of String,
      "type"               => [] of String,
      "force"              => [] of String,
      "path"               => [] of String,
      "comment"            => [] of String,
      "regenerate"         => [] of String,
      "passphrase"         => [] of String,
      "private_key_format" => [] of String,
      "backend"            => [] of String,
      "mode"               => [] of String,
      "owner"              => [] of String,
      "group"              => [] of String,
      "seuser"             => [] of String,
      "serole"             => [] of String,
      "selevel"            => [] of String,
      "setype"             => [] of String,
      "attributes"         => ["attr"],
      "unsafe_writes"      => [] of String,
    }

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      path = expand_tilde(@params["path"])
      pub_path = "#{path}.pub"
      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)

      type = @params["type"]? || "rsa"

      # Real backend __init__ order (KeypairBackend): _get_size first,
      # THEN _validate_path - both run for EVERY state, BEFORE the
      # absent branch (live-verified vs 2.19.11: state=absent with an
      # undersized size still fails the size validation).
      size_result = resolve_size(type, @params["size"]?.try(&.to_i))
      return size_result if size_result.is_a?(PluginResult)
      size = size_result

      if path_err = validate_path(path)
        return path_err
      end

      # Real select_backend + the backend constructors' own checks: the
      # opensshbin backend rejects any private_key_format other than
      # "auto"; the cryptography backend rejects rsa1.
      if backend_err = resolve_backend(type)
        return backend_err
      end

      return remove(path, pub_path, check_mode) if state == "absent"

      ensure_present(path, pub_path, type, size, check_mode)
    end

    # AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required -> types (spec declaration order) -> choices ->
    # mutually_exclusive -> unsupported (deferred last). No
    # required_together/required_if on this module.
    private def validate_arguments : PluginResult?
      return missing_required_error(["path"]) unless @params["path"]?

      if raw = @params["size"]?
        return int_type_error("size", raw) unless raw.to_i32?
      end
      %w[force unsafe_writes].each do |param|
        if raw = @params[param]?
          return bool_type_error(param, raw) unless bool_convertible?(raw)
        end
      end

      {"state"              => %w[present absent],
       "type"               => %w[rsa dsa rsa1 ecdsa ed25519],
       "regenerate"         => %w[never fail partial_idempotence full_idempotence always],
       "private_key_format" => %w[auto pkcs1 pkcs8 ssh],
       "backend"            => %w[auto cryptography opensshbin]}.each do |param, allowed|
        if value = @params[param]?
          unless allowed.includes?(value)
            return choices_error(param, allowed, value)
          end
        end
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.openssh_keypair", unsupported, SPEC)
      end
      nil
    end

    private def ensure_present(path : String, pub_path : String, type : String, size : Int32, check_mode : Bool) : PluginResult
      force = true?(@params["force"]?)
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
      return PluginResult.new(changed: true, failed: false, msg: "Would generate SSH keypair at #{path} (check mode)", key_order: SUCCESS_KEY_ORDER, size: size, type: type, filename: path) if check_mode
      generate(path, pub_path, type, size, comment, passphrase)
    end

    private def unreadable_key_error(path : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Unable to read the key. The key is protected with a passphrase or broken. Will not proceed. To force regeneration, call the module with `regenerate` set to `full_idempotence` or `always`, or with `force=true`.")
    end

    COLLECTION_MINIMUM_CRYPTOGRAPHY_VERSION = "3.3"

    # Real select_backend + the two backend constructors' own param
    # checks, in real order. backend=auto picks opensshbin whenever the
    # ssh-keygen binary exists and no passphrase was given, then falls
    # back to the cryptography library; explicit backends fail with
    # their own availability messages.
    private def resolve_backend(type : String) : PluginResult?
      backend = @params["backend"]? || "auto"
      passphrase = @params["passphrase"]?
      can_use_opensshbin = !!Process.find_executable("ssh-keygen")
      can_use_cryptography = cryptography_available?

      if backend == "auto"
        if can_use_opensshbin && !passphrase
          backend = "opensshbin"
        elsif can_use_cryptography
          backend = "cryptography"
        else
          return PluginResult.new(changed: false, failed: true,
            msg: "Cannot find either the OpenSSH binary in the PATH or cryptography >= #{COLLECTION_MINIMUM_CRYPTOGRAPHY_VERSION} installed on this system")
        end
      end

      if backend == "opensshbin"
        return PluginResult.new(changed: false, failed: true,
          msg: "Cannot find the OpenSSH binary in the PATH") unless can_use_opensshbin
        if (@params["private_key_format"]? || "auto") != "auto"
          return PluginResult.new(changed: false, failed: true,
            msg: "'auto' is the only valid option for 'private_key_format' when 'backend' is not 'cryptography'")
        end
        return nil
      end

      unless can_use_cryptography
        return PluginResult.new(changed: false, failed: true,
          msg: Krikri.missing_required_lib_message("cryptography >= #{COLLECTION_MINIMUM_CRYPTOGRAPHY_VERSION}", python_interpreter))
      end
      if type == "rsa1"
        return PluginResult.new(changed: false, failed: true,
          msg: "RSA1 keys are not supported by the cryptography backend")
      end
      nil
    end

    # The cryptography library's availability, probed through the
    # target's python3 (the same way real imports it). Only consulted
    # when the opensshbin path is unavailable - matches Ansible's
    # can_use_cryptography short-circuit in select_backend.
    private def cryptography_available? : Bool
      ["python3", "python"].each do |interpreter|
        next unless Process.find_executable(interpreter)
        probe = "import cryptography\n" \
                "from cryptography.hazmat.primitives.serialization import Encoding\n" \
                "parts = cryptography.__version__.split('.')\n" \
                "print('yes' if (int(parts[0]), int(parts[1])) >= (3, 3) else 'no')"
        io = IO::Memory.new
        status = Process.run(interpreter, {"-c", probe}, output: io, error: Process::Redirect::Close)
        next unless status.success?
        return io.to_s.strip == "yes"
      end
      false
    end

    private def python_interpreter : String
      ["python3", "python"].each do |interpreter|
        next unless Process.find_executable(interpreter)
        io = IO::Memory.new
        status = Process.run(interpreter, {"-c", "import os, sys; print(os.path.realpath(sys.executable))"}, output: io, error: Process::Redirect::Close)
        return io.to_s.strip if status.success?
      end
      "python3"
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
        if size < 1024
          return PluginResult.new(changed: false, failed: true, msg: "For RSA keys, the minimum size is 1024 bits and the default is 4096 bits. Attempting to use bit lengths under 1024 will cause the module to fail.")
        end
        size
      when "dsa"
        size = requested || 1024
        return PluginResult.new(changed: false, failed: true, msg: "DSA keys must be exactly 1024 bits as specified by FIPS 186-2.") if size != 1024
        size
      when "ecdsa"
        size = requested || 256
        if !([256, 384, 521].includes?(size))
          return PluginResult.new(changed: false, failed: true, msg: "For ECDSA keys, size determines the key length by selecting from one of three elliptic curve sizes: 256, 384 or 521 bits. Attempting to use bit lengths other than these three values for ECDSA keys will cause the module to fail.")
        end
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

      begin
        atomic_move(tmp, path)
        atomic_move(tmp_pub, pub_path)
      ensure
        # On success these are already gone (rename or the EXDEV
        # copy-then-delete in BasePlugin#atomic_move consumed them);
        # on failure, don't leak ssh-keygen material in /tmp.
        File.delete(tmp) if File.exists?(tmp)
        File.delete(tmp_pub) if File.exists?(tmp_pub)
      end
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

    # Both files carry the file-common attributes - a change to either
    # one counts as changed (the Ansible module's
    # set_fs_attributes_if_different is applied to the pair).
    private def apply_attrs(path : String, pub_path : String) : Bool
      changed = false
      {path, pub_path}.each do |file|
        next unless File.exists?(file)
        before = File.info(file).permissions.value
        apply_owner_group_mode(file, @params["owner"]?, @params["group"]?, @params["mode"]?)
        changed ||= File.info(file).permissions.value != before
      end
      changed
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
        key_order: SUCCESS_KEY_ORDER,
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
      return PluginResult.new(changed: exists, failed: false, msg: exists ? "Would remove #{path}/#{pub_path} (check mode)" : "already absent", key_order: SUCCESS_KEY_ORDER) if check_mode
      return PluginResult.new(changed: false, failed: false, msg: "already absent", key_order: SUCCESS_KEY_ORDER) unless exists

      File.delete(path) if File.exists?(path)
      File.delete(pub_path) if File.exists?(pub_path)
      PluginResult.new(changed: true, failed: false, msg: "Removed #{path} and #{pub_path}", key_order: SUCCESS_KEY_ORDER)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::OpensshKeypairPlugin.new(config)
plugin.run
