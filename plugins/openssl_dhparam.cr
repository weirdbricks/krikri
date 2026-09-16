#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

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
    include PluginHelpers::AnsibleArgValidation

    # The real module's argument_spec plus the file-common args its
    # add_file_common_args=True injects (the only alias is
    # attributes->attr).
    SPEC = {
      "state"                 => [] of String,
      "size"                  => [] of String,
      "force"                 => [] of String,
      "path"                  => [] of String,
      "backup"                => [] of String,
      "select_crypto_backend" => [] of String,
      "return_content"        => [] of String,
      "mode"                  => [] of String,
      "owner"                 => [] of String,
      "group"                 => [] of String,
      "seuser"                => [] of String,
      "serole"                => [] of String,
      "selevel"               => [] of String,
      "setype"                => [] of String,
      "attributes"            => ["attr"],
      "unsafe_writes"         => [] of String,
    }

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      path = @params["path"]?
      path = expand_tilde(path.not_nil!)
      state = @params["state"]? || "present"
      size = @params["size"]?.try(&.to_i) || 4096
      force = true?(@params["force"]?)
      check_mode = true?(@params["_ansible_check_mode"]?)

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

    # Real AnsibleModule validation order (ArgumentSpecValidator.validate):
    # required -> types (spec declaration order) -> choices ->
    # unsupported (deferred last). No required_together/required_if/
    # mutually_exclusive on this module.
    private def validate_arguments : PluginResult?
      return missing_required_error(["path"]) unless @params["path"]?

      if raw = @params["size"]?
        return int_type_error("size", raw) unless raw.to_i32?
      end
      %w[force backup return_content unsafe_writes].each do |param|
        if raw = @params[param]?
          return bool_type_error(param, raw) unless bool_convertible?(raw)
        end
      end

      if value = @params["state"]?
        unless %w[absent present].includes?(value)
          return choices_error("state", %w[absent present], value)
        end
      end
      if value = @params["select_crypto_backend"]?
        unless %w[auto cryptography openssl].includes?(value)
          return choices_error("select_crypto_backend", %w[auto cryptography openssl], value)
        end
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("community.crypto.openssl_dhparam", unsupported, SPEC)
      end
      nil
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

    private def backup(path : String) : Nil
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
