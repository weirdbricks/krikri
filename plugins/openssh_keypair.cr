#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # openssh_keypair plugin - generates an SSH host/user keypair.
  # Compatible (for the parameters implemented here) with Ansible's
  # community.crypto.openssh_keypair module.
  #
  # Shells out to the target's own `ssh-keygen` binary - same "no
  # vendored crypto library for this, shell the real tool" trade-off
  # already made for openssl_dhparam.cr.
  #
  # Supported parameters:
  # - path (required)
  # - type: rsa (default) / dsa / ecdsa / ed25519
  # - size: bit length - only meaningful for rsa/dsa/ecdsa (ed25519 and
  #   dsa both have a fixed real size; a size: given for either is
  #   ignored, matching what ssh-keygen itself does)
  # - state: present (default) / absent
  # - owner/group/mode
  # - regenerate: any value - always treated as "regenerate on a type
  #   or size mismatch", real Ansible's own "partial_idempotence"
  #   behavior (its default) and the only real-world value konstruktoid/
  #   ansible-role-hardening's own tasks use. "never"/"fail" (raise
  #   instead of silently regenerating) aren't implemented.
  # - check_mode
  #
  # Idempotency: if the file exists, its actual type and bit size are
  # read back via `ssh-keygen -lf path` (format: "SIZE SHA256:... comment
  # (TYPE)") and compared against type:/size: - regenerating only on a
  # mismatch, or if the file can't be parsed as a keypair at all
  # (corrupt/truncated).
  #
  # Not implemented: comment:, passphrase:, backup:, regenerate: never/
  # fail/always/full_idempotence (all fall back to partial_idempotence's
  # behavior).
  class OpensshKeypairPlugin < BasePlugin
    FIXED_SIZE_TYPES = {"ed25519", "dsa"}

    def execute : PluginResult
      path = @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path") unless path

      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      if state == "absent"
        return ensure_absent(path, check_mode)
      end

      type = @params["type"]? || "rsa"
      size = desired_size(type)

      ensure_present(path, type, size, check_mode)
    end

    private def desired_size(type : String) : Int32?
      return nil if FIXED_SIZE_TYPES.includes?(type)
      @params["size"]?.try(&.to_i)
    end

    private def ensure_absent(path : String, check_mode : Bool) : PluginResult
      pub_path = "#{path}.pub"
      exists = File.exists?(path) || File.exists?(pub_path)
      return PluginResult.new(changed: false, failed: false, msg: "#{path} already absent") unless exists
      return PluginResult.new(changed: true, failed: false, msg: "#{path} would be removed") if check_mode

      File.delete(path) if File.exists?(path)
      File.delete(pub_path) if File.exists?(pub_path)
      PluginResult.new(changed: true, failed: false, msg: "Removed #{path}")
    end

    private def ensure_present(path : String, type : String, size : Int32?, check_mode : Bool) : PluginResult
      if File.exists?(path) && matches?(path, type, size)
        apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?) unless check_mode
        return PluginResult.new(changed: false, failed: false, msg: "#{path} already is a #{type} key#{size ? " (#{size} bits)" : ""}")
      end

      return PluginResult.new(changed: true, failed: false, msg: "Would generate a #{type} keypair at #{path}") if check_mode

      File.delete(path) if File.exists?(path)
      File.delete("#{path}.pub") if File.exists?("#{path}.pub")

      cmd = String.build do |cmd_str|
        cmd_str << "ssh-keygen -t " << type
        cmd_str << " -b " << size if size
        cmd_str << " -f " << path << " -N '' -q"
      end

      result = remote_exec(cmd)
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to generate SSH keypair", stderr: result[:stderr])
      end

      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      apply_owner_group_mode("#{path}.pub", @params["owner"]?, @params["group"]?, nil)
      PluginResult.new(changed: true, failed: false, msg: "Generated #{type} keypair at #{path}")
    end

    # Reads back an existing key's real type/size via `ssh-keygen -lf`
    # and compares to what's wanted - nil size (ed25519/dsa) always
    # matches on size, since ssh-keygen enforces a single fixed size for
    # those types anyway.
    private def matches?(path : String, type : String, size : Int32?) : Bool
      result = remote_exec("ssh-keygen -lf #{path}")
      return false unless result[:exit_code] == 0

      match = result[:stdout].match(/^(\d+)\s+\S+\s+.*\(([A-Za-z0-9-]+)\)\s*$/)
      return false unless match

      current_size = match[1].to_i
      current_type = match[2].downcase

      return false unless current_type == type
      size.nil? || current_size == size
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::OpensshKeypairPlugin.new(config)
plugin.run
