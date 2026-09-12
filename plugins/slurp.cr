#!/usr/bin/env crystal

# slurp module (ansible.builtin.slurp) - reads a file's content from the
# target and returns it, base64-encoded.
#
# Entirely unimplemented before - robertdebock.ca's own "generate_ca_
# certs | Save ca certificate" task (`slurp: {src: ...}`, reading back a
# just-generated cert to embed its content elsewhere) silently dropped.
#
# Always base64-encodes, unconditionally: real ansible-core's argument_
# spec is exactly `src` (type path, required, aliases [path]) - there is
# NO `armor` param. An earlier version of this plugin invented one
# (default true, `armor: false` returning raw UTF-8) and claimed it
# mirrored real slurp.py; nothing in real Ansible has it (ascii-armor is
# a GPG/rpm-key concept, not a slurp one). Real Ansible rejects an
# `armor:` task at argument-spec validation, so this engine does too -
# same message shape command.cr/shell.cr use for their removed `warn`
# param.

require "json"
require "base64"
require "../src/krikri/base_plugin"

module Krikri
  class SlurpPlugin < BasePlugin
    def execute : PluginResult
      src = @params["src"]? || @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: src") unless src

      if @params.has_key?("armor")
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (ansible.builtin.slurp) module: armor. Supported parameters include: src (path)."
        )
      end

      return PluginResult.new(changed: false, failed: true, msg: "Source is a directory and must be a file: #{src}") if Dir.exists?(src)

      begin
        bytes = File.read(src).to_slice
      rescue ex : File::NotFoundError
        return PluginResult.new(changed: false, failed: true, msg: "File not found: #{src}")
      rescue ex : File::AccessDeniedError
        return PluginResult.new(changed: false, failed: true, msg: "File is not readable: #{src}")
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Unable to slurp file: #{src}: #{ex.message}")
      end

      PluginResult.new(changed: false, failed: false, msg: "", content: Base64.strict_encode(bytes), source: src, encoding: "base64")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SlurpPlugin.new(config)
plugin.run
