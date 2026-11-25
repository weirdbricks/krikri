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

      # slurp's src is a `type: path` argspec option, and Ansible's
      # check_type_path runs os.path.expanduser(os.path.expandvars(...))
      # before the module body ever looks at it - so both the file it
      # opens and the `source`/msg text carry the expanded path.
      # jesperberth.el_k3s's own "Set Kubectl release" slurps the
      # `~/stable.txt` its get_url task just wrote; unexpanded, the read
      # failed with "File not found: ~/stable.txt" and the play aborted
      # (issue #1568).
      src = expand_tilde(expand_dollar_vars(src))

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
      # real 2.21.6 on a non-UTF-8 file).
      raw_content = String.new(bytes)
      return utf8_refusal_result(bytes) if !armor && !raw_content.valid_encoding?

      PluginResult.new(
        changed: false, failed: false, msg: "",
        content: armor ? Base64.strict_encode(bytes) : raw_content,
        source: src, encoding: armor ? "base64" : "utf-8",
        failed_flag: false, key_order: SUCCESS_KEY_ORDER
      )
    end

    # Real raises the refusal while deserializing the MODULE's result, so
    # the task executor wraps it in an AnsibleTaskError: the registered/fatal
    # msg carries the "Task failed: " brief while the [ERROR] block's own
    # text does not (live-verified vs 2.21.6, issue #1801).
    private def utf8_refusal_result(bytes : Bytes) : PluginResult
      start, run, first = utf8_encode_error(bytes)
      detail = if run > 1
                 "Refusing to deserialize an invalid UTF8 string value: 'utf-8' codec can't encode characters in position #{start}-#{start + run - 1}: surrogates not allowed"
               else
                 "Refusing to deserialize an invalid UTF8 string value: 'utf-8' codec can't encode character '\\u#{(0xDC00 | first).to_s(16)}' in position #{start}: surrogates not allowed"
               end
      PluginResult.new(changed: false, failed: true, msg: "Task failed: #{detail}", _ansible_error_detail: detail)
    end

    # CPython decodes the module's `content` string with surrogateescape, so
    # every byte the utf-8 codec cannot fold into a valid sequence becomes
    # one lone surrogate character. Its re-encode failure reports the FIRST
    # such run, with positions counted in CHARACTERS (each valid multi-byte
    # sequence before the run counts once), and prints the lone surrogate's
    # own escape when the run is a single character but the plain range when
    # it is longer - "'\udcff' in position 12" vs "in position 12-13"
    # (live-verified vs ansible-core 2.21.6, issue #1801).
    private def utf8_encode_error(bytes : Bytes) : {Int32, Int32, UInt8}
      char_index = 0
      index = 0
      while index < bytes.size
        if length = valid_utf8_length(bytes, index)
          index += length
          char_index += 1
          next
        end

        start = char_index
        first = bytes[index]
        while index < bytes.size && valid_utf8_length(bytes, index).nil?
          index += 1
          char_index += 1
        end
        return {start, char_index - start, first}
      end
      {0, 0, 0_u8}
    end

    # Length of the well-formed UTF-8 sequence starting at `index`, or nil.
    # Stricter than a continuation-byte check alone: CPython also rejects
    # overlong forms and the encoded-surrogate range (0xED 0xA0..0xBF), so a
    # "\xed\xb3\xbf" run is reported as three surrogates, not skipped.
    private def valid_utf8_length(bytes : Bytes, index : Int32) : Int32? # ameba:disable Metrics/CyclomaticComplexity
      byte = bytes[index]
      return 1 if byte < 0x80

      if byte.in?(0xC2..0xDF)
        return 2 if utf8_continuation?(bytes, index + 1)
      elsif byte.in?(0xE0..0xEF)
        second_low = byte == 0xE0 ? 0xA0 : 0x80
        second_high = byte == 0xED ? 0x9F : 0xBF
        if (second = bytes[index + 1]?) && second.in?(second_low..second_high) && utf8_continuation?(bytes, index + 2)
          return 3
        end
      elsif byte.in?(0xF0..0xF4)
        second_low = byte == 0xF0 ? 0x90 : 0x80
        second_high = byte == 0xF4 ? 0x8F : 0xBF
        if (second = bytes[index + 1]?) && second.in?(second_low..second_high) &&
           utf8_continuation?(bytes, index + 2) && utf8_continuation?(bytes, index + 3)
          return 4
        end
      end
      nil
    end

    private def utf8_continuation?(bytes : Bytes, index : Int32) : Bool
      (byte = bytes[index]?) ? byte.in?(0x80..0xBF) : false
    end

    private SUCCESS_KEY_ORDER = %w[content source encoding failed changed]
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SlurpPlugin.new(config)
plugin.run
