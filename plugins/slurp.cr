#!/usr/bin/env crystal

# slurp module (ansible.builtin.slurp) - reads a file's content from the
# target and returns it, base64-encoded by default.
#
# Entirely unimplemented before - robertdebock.ca's own "generate_ca_
# certs | Save ca certificate" task (`slurp: {src: ...}`, reading back a
# just-generated cert to embed its content elsewhere) silently dropped.
#
# `armor: false` (real Ansible's own non-default) returns the raw bytes
# UTF-8-decoded rather than base64 - matches src/modules/slurp.py
# exactly, including its own comment that this isn't really "current
# file encoding" but rather what the value looks like once serialized
# as JSON.

require "json"
require "base64"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class SlurpPlugin < BasePlugin
    def execute : PluginResult
      src = @params["src"]? || @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: src") unless src

      armor = @params["armor"]?.nil? || true?(@params["armor"]?)

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

      if armor
        PluginResult.new(changed: false, failed: false, msg: "", content: Base64.strict_encode(bytes), source: src, encoding: "base64")
      else
        PluginResult.new(changed: false, failed: false, msg: "", content: String.new(bytes), source: src, encoding: "utf-8")
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::SlurpPlugin.new(config)
plugin.run
