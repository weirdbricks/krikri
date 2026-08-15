#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # openssl_dhparam plugin - generates a Diffie-Hellman parameters file.
  # Compatible with Ansible's community.crypto.openssl_dhparam module.
  #
  # Shells out to the target's own `openssl dhparam` binary (real
  # Ansible's own module does the same when the `cryptography` Python
  # library isn't available, and always did in older versions) - this
  # codebase already has precedent for shelling to `openssl` (unarchive/
  # authorized_key don't, but there's no vendored DH-param generation
  # library here at all, unlike the zstd/gzip/xz/bz2 codec cases
  # mysql_db.cr's dump/import prefers a native Crystal implementation
  # for).
  #
  # Supported parameters:
  # - path (required)
  # - size: bit length (default 4096)
  # - state: present (default) / absent
  # - force: bool - regenerate even if a file of the right size already
  #   exists (default false)
  # - owner/group/mode
  # - check_mode
  #
  # Idempotency: if the file exists and isn't force:'d, its actual
  # bit length is read back via `openssl dhparam -in path -text -noout`
  # and compared to size: - regenerating only on a mismatch (or a file
  # openssl itself can't parse, e.g. corrupt/truncated).
  #
  # Not implemented: backup:.
  class OpensslDhparamPlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path") unless path
      path = expand_tilde(path)

      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      if state == "absent"
        return ensure_absent(path, check_mode)
      end

      size = (@params["size"]? || "4096").to_i
      force = is_true?(@params["force"]?)

      ensure_present(path, size, force, check_mode)
    end

    private def ensure_absent(path : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "#{path} already absent") unless File.exists?(path)
      return PluginResult.new(changed: true, failed: false, msg: "#{path} would be removed") if check_mode

      File.delete(path)
      PluginResult.new(changed: true, failed: false, msg: "Removed #{path}")
    end

    private def ensure_present(path : String, size : Int32, force : Bool, check_mode : Bool) : PluginResult
      if !force && File.exists?(path) && current_size(path) == size
        apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?) unless check_mode
        return PluginResult.new(changed: false, failed: false, msg: "#{path} already contains #{size}-bit DH parameters")
      end

      return PluginResult.new(changed: true, failed: false, msg: "Would generate #{size}-bit DH parameters at #{path}") if check_mode

      result = remote_exec("openssl dhparam -out #{path} #{size}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to generate DH parameters", stderr: result[:stderr])
      end

      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      PluginResult.new(changed: true, failed: false, msg: "Generated #{size}-bit DH parameters at #{path}")
    end

    # Reads back the bit length of an existing DH params file, or nil if
    # openssl can't parse it at all (missing/corrupt) - either way that's
    # "doesn't match", so #ensure_present regenerates it.
    private def current_size(path : String) : Int32?
      result = remote_exec("openssl dhparam -in #{path} -text -noout")
      return nil unless result[:exit_code] == 0

      if match = result[:stdout].match(/\((\d+) bit\)/)
        match[1].to_i
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::OpensslDhparamPlugin.new(config)
plugin.run
