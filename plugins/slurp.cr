#!/usr/bin/env crystal

# slurp module (ansible.builtin.slurp) - reads a file's content from the
# target and returns it, base64-encoded.
#
# Entirely unimplemented before - robertdebock.ca's own "generate_ca_
# certs | Save ca certificate" task (`slurp: {src: ...}`, reading back a
# just-generated cert to embed its content elsewhere) silently dropped.
#
# 2.21 added the `armor` param (type bool, default true): armor=false
# returns the file content as a raw UTF-8 string with encoding "utf-8"
# instead of base64 (live-verified vs real 2.21.6: content "floridian-
# goat\n" / encoding "utf-8"). An earlier version of this plugin invented
# armor for a pre-2.21 argspec and then rejected it as unsupported when
# the 2.19 argspec said no such param exists - with the 2.21.6 capture
# in data/argspecs.json the parameter is real and must be implemented.
# Python's truthiness applies to the bool conversion; the default is
# true.

require "json"
require "base64"
require "../src/krikri/base_plugin"

module Krikri
  class SlurpPlugin < BasePlugin
    def execute : PluginResult
      src = @params["src"]? || @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: src") unless src

      armor = @params["armor"]?.nil? ? true : true?(@params["armor"])

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
      # armor=false hands the raw bytes to the controller's JSON
      # deserialization, which refuses invalid UTF-8 (live-verified vs
      # real 2.21.6 on a non-UTF-8 file). CPython's codec error reports
      # the byte range of the first ill-formed sequence as "position
      # S-E"; krikri derives the same pair from the first invalid byte.
      raw_content = String.new(bytes)
      if !armor && !raw_content.valid_encoding?
        start = invalid_utf8_start(bytes)
        return PluginResult.new(
          changed: false, failed: true,
          msg: "Refusing to deserialize an invalid UTF8 string value: 'utf-8' codec can't encode characters in position #{start}-#{start + 1}: surrogates not allowed"
        )
      end

      PluginResult.new(
        changed: false, failed: false, msg: "",
        content: armor ? Base64.strict_encode(bytes) : raw_content,
        source: src, encoding: armor ? "base64" : "utf-8",
        failed_flag: false, key_order: SUCCESS_KEY_ORDER
      )
    end

    # Index of the first byte that starts an ill-formed UTF-8 sequence,
    # mirroring what CPython's utf-8 codec reports as the error position.
    private def invalid_utf8_start(bytes : Bytes) : Int32
      bytes.size.times do |i|
        b = bytes[i]
        if b < 0x80
          next
        elsif b < 0xC2 || b > 0xF4
          return i
        elsif b < 0xE0
          return i unless bytes[i + 1]?.try &.in?(0x80..0xBF)
        elsif b < 0xF0
          return i unless bytes[i + 1]?.try(&.in?(0x80..0xBF)) && bytes[i + 2]?.try(&.in?(0x80..0xBF))
          return i if b == 0xE0 && (bytes[i + 1] || 0) < 0xA0
        else
          return i unless bytes[i + 1]?.try(&.in?(0x80..0xBF)) && bytes[i + 2]?.try(&.in?(0x80..0xBF)) && bytes[i + 3]?.try(&.in?(0x80..0xBF))
          return i if b == 0xF0 && (bytes[i + 1] || 0) < 0x90
          return i if b == 0xF4 && (bytes[i + 1] || 0) > 0x8F
        end
      end
      0
    end

    private SUCCESS_KEY_ORDER = %w[content source encoding failed changed]
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SlurpPlugin.new(config)
plugin.run
