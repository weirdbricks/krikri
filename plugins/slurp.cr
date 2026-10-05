#!/usr/bin/env crystal

# slurp module (ansible.builtin.slurp) - reads a file's content from the
# target and returns it, base64-encoded.
#
# Entirely unimplemented before - robertdebock.ca's own "generate_ca_
# certs | Save ca certificate" task (`slurp: {src: ...}`, reading back a
# just-generated cert to embed its content elsewhere) silently dropped.
#
# Always base64-encodes, unconditionally: ansible-core's argument_
# spec is exactly `src` (type path, required, aliases [path]) - there is
# NO `armor` param. An earlier version of this plugin invented one
# (default true, `armor: false` returning raw UTF-8) and claimed it
# mirrored real slurp.py; nothing in Ansible has it (ascii-armor is
# a GPG/rpm-key concept, not a slurp one). Ansible rejects an
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

      # Ansible 2.19.11's slurp fails the task with msg "File not found: <src>"
      # (etc.) in the result dict, but the module process's OSError is what
      # the [ERROR] block renders, appended to that same text: "File not
      # found: <src>: [Errno 2] No such file or directory: '<src>'". The
      # errno wording is CPython's, not Crystal's ("Error opening file with
      # mode 'r': ..."), so it is spelled out here; _ansible_error_detail
      # carries the block text and is stripped from every result dump, so
      # the fatal JSON keeps Ansible's msg verbatim.
      return PluginResult.new(
        changed: false, failed: true,
        msg: "Source is a directory and must be a file: #{src}",
        _ansible_error_detail: "Source is a directory and must be a file: #{src}: [Errno 21] Is a directory: '#{src}'"
      ) if Dir.exists?(src)

      begin
        bytes = File.read(src).to_slice
      rescue File::NotFoundError
        return PluginResult.new(
          changed: false, failed: true,
          msg: "File not found: #{src}",
          _ansible_error_detail: "File not found: #{src}: [Errno 2] No such file or directory: '#{src}'"
        )
      rescue File::AccessDeniedError
        return PluginResult.new(
          changed: false, failed: true,
          msg: "File is not readable: #{src}",
          _ansible_error_detail: "File is not readable: #{src}: [Errno 13] Permission denied: '#{src}'"
        )
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Unable to slurp file: #{src}: #{ex.message}")
      end

      # Real slurp's registered result runs content, source, encoding,
      # failed, changed - `changed` LAST and `failed: false` explicitly
      # present (live-verified vs 2.19.11 via `{{ r | to_json }}` on a
      # registered slurp: task; check mode keeps the same order). The
      # failed_flag opt-in makes the success result carry failed: false
      # so the reorder can place it before changed - without it the
      # executor's missing-failed backfill would append failed AFTER
      # changed, Ansible's exact opposite.
      PluginResult.new(changed: false, failed: false, msg: "", content: Base64.strict_encode(bytes), source: src, encoding: "base64", failed_flag: false, key_order: SUCCESS_KEY_ORDER)
    end

    private SUCCESS_KEY_ORDER = %w[content source encoding failed changed]
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SlurpPlugin.new(config)
plugin.run
