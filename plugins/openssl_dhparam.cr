#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # openssl_dhparam plugin (community.crypto.openssl_dhparam) - generates
  # OpenSSL Diffie-Hellman parameters. Ported from the real module's
  # `openssl` backend (shells to the `openssl dhparam` binary) - the
  # module's own `cryptography`-library backend is skipped since this
  # codebase has no Python runtime to lean on; the openssl CLI backend
  # is the module's own fallback and produces byte-identical params.
  #
  # Parameters: path (required), size (default 4096), state (present/
  # absent, default present), force, backup, owner/group/mode,
  # check_mode. select_crypto_backend/return_content are accepted but
  # only the openssl-CLI-equivalent behavior applies.
  class OpensslDhparamPlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path") unless path

      path = expand_tilde(path)
      state = @params["state"]? || "present"
      size = (@params["size"]? || "4096").to_i
      force = true?(@params["force"]?)
      check_mode = true?(@params["check_mode"]?)

      base_dir = File.dirname(path)
      unless Dir.exists?(base_dir)
        return PluginResult.new(changed: false, failed: true, msg: "The directory '#{base_dir}' does not exist or the file is not a directory")
      end

      if state == "absent"
        return remove(path, check_mode)
      end

      valid = !force && File.exists?(path) && params_valid?(path, size)

      if valid
        changed = apply_attrs(path)
        return PluginResult.new(changed: changed, failed: false, msg: "DH parameters already valid at #{path}", size: size, filename: path)
      end

      return PluginResult.new(changed: true, failed: false, msg: "Would generate DH parameters at #{path} (check mode)", size: size, filename: path) if check_mode

      generate(path, size)
    end

    private def remove(path : String, check_mode : Bool) : PluginResult
      exists = File.exists?(path)
      return PluginResult.new(changed: exists, failed: false, msg: exists ? "Would remove #{path} (check mode)" : "#{path} already absent") if check_mode
      return PluginResult.new(changed: false, failed: false, msg: "#{path} already absent") unless exists

      backup(path)
      File.delete(path)
      PluginResult.new(changed: true, failed: false, msg: "Removed #{path}")
    end

    # Mirrors DHParameterOpenSSL#_check_params_valid: `openssl dhparam
    # -check -text -noout -in <path>`, parse "Parameters: (NNNN bit)"
    # from stdout, reject on a non-zero exit or a WARNING in either
    # stream.
    private def params_valid?(path : String, size : Int32) : Bool
      stdout = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", ["dhparam", "-check", "-text", "-noout", "-in", path], output: stdout, error: err)
      return false unless status.success?

      text = stdout.to_s
      match = text.match(/Parameters:\s+\((\d+) bit\)/)
      return false unless match

      return false if text.includes?("WARNING") || err.to_s.includes?("WARNING")

      match[1].to_i == size
    end

    private def generate(path : String, size : Int32) : PluginResult
      tmp = File.tempname("dhparam")
      stdout = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("openssl", ["dhparam", "-out", tmp, size.to_s], output: stdout, error: err)
      unless status.success?
        File.delete(tmp) if File.exists?(tmp)
        return PluginResult.new(changed: false, failed: true, msg: "openssl dhparam failed: #{err}")
      end

      backup(path)
      File.rename(tmp, path)
      apply_attrs(path)
      PluginResult.new(changed: true, failed: false, msg: "Generated DH parameters at #{path}", size: size, filename: path)
    end

    private def apply_attrs(path : String) : Bool
      before = File.info(path).permissions.value
      apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      File.info(path).permissions.value != before
    rescue
      false
    end

    private def backup(path : String)
      return unless true?(@params["backup"]?)
      return unless File.exists?(path)
      timestamp = Time.local.to_s("%Y-%m-%d@%H:%M~")
      File.copy(path, "#{path}.#{timestamp}")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::OpensslDhparamPlugin.new(config)
plugin.run
