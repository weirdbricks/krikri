#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Sysctl plugin - manages entries in a sysctl config file (and
  # optionally applies them to the running kernel). Compatible with
  # Ansible's ansible.posix.sysctl module.
  #
  # Supported parameters:
  # - name: dot-separated sysctl key (required)
  # - value: desired value (required when state: present)
  # - state: present (default) | absent
  # - sysctl_file: config file to edit (default /etc/sysctl.conf)
  # - sysctl_set: also verify/apply the value against the running kernel
  #   via `sysctl -w` (default false - most usage is just editing the
  #   file; this needs root/appropriate capabilities the same way
  #   Ansible's does)
  # - reload: run `sysctl -p <sysctl_file>` to apply the file's contents
  #   to the running kernel when the file changed (default true, matching
  #   Ansible's default - also needs root/capabilities for real)
  # - ignoreerrors: pass -e to the underlying sysctl command
  # - check_mode: report what would change without writing anything or
  #   touching the running kernel
  #
  # File format and rewrite logic verified by reading the
  # ansible.posix sysctl.py source directly, not assumed from docs:
  # `key=value\n` (no surrounding spaces), comments and blank lines
  # preserved verbatim, first occurrence of a duplicated key wins (later
  # duplicates are dropped when the file is rewritten), state: absent
  # drops the line entirely rather than commenting it out.
  #
  # Native vs shell-out: the config-file read (`cat` -> native
  # `File.read_lines`) is now native for local connections (its write
  # path already branched on `local_connection?`, and the read keeps
  # an SSH `cat` branch for non-local hosts for the same reason as
  # mount.cr). The two live-kernel calls - `sysctl -w` (sysctl_set:) and
  # `sysctl -p <file>` (reload:) - are genuine system operations with no
  # native Crystal equivalent and stay shelled-out.
  #
  # Not implemented: BSD/Solaris-specific sysctl command syntax (Linux
  # `sysctl -w key=value` / `sysctl -p file` only).
  class SysctlPlugin < BasePlugin
    DEFAULT_SYSCTL_FILE = "/etc/sysctl.conf"

    # ansible.posix.sysctl's very first act is importing `to_native` from
    # `ansible.module_utils._text` (sysctl.py:108 in the 2.1.x sources),
    # which ansible-core turned into a shim whose __getattr__ deprecates
    # that import. The deprecation is collected before any argument
    # validation runs, so it rides EVERY result the module returns - the
    # early "missing required argument" fail_json exits included - and
    # prints on the console once per run (Display dedups the text) with
    # the one-time "can be disabled" hint before the first one.
    # Live-verified against ansible-core 2.21.6 + the ansible.posix 2.1.x
    # tree (officel.sysctl-conf round 29902200, issue #992). ansible.posix
    # 2.2.x imports to_native from
    # `ansible.module_utils.common.text.converters` (sysctl.py:134)
    # instead and triggers nothing - so the entry rides only the 2.1.x
    # module line, the release gate issue #1060's split calls for.
    MODULE_UTILS_TEXT_DEPRECATION_TEXT = "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
                                         "This feature will be removed from ansible-core version 2.24. " \
                                         "Use ansible.module_utils.common.text.converters instead."

    # Attached through BasePlugin#finalize_result so that every exit path
    # carries it, exactly like the module's own import-time collection.
    # The registered entry's key order is real's - msg, collection_name,
    # version, deprecator, the shape ansible-core's _return_formatted
    # builds - captured through `{{ r | to_json }}` rather than a -v dump,
    # which sorts alphabetically.
    def finalize_result(result : PluginResult) : PluginResult
      return result unless resolved_collection_version_before?(2, 2, 0)
      result.extra["deprecations"] = JSON::Any.new([JSON::Any.new({
        "msg"             => JSON::Any.new("Importing 'to_native' from 'ansible.module_utils._text' is deprecated."),
        "collection_name" => JSON::Any.new("ansible.builtin"),
        "version"         => JSON::Any.new("2.24"),
        "deprecator"      => JSON::Any.new({
          "resolved_name" => JSON::Any.new("ansible.builtin"),
          "type"          => JSON::Any.new(nil),
        }),
      })])
      result.extra["_ansible_core_deprecations"] = JSON::Any.new([JSON::Any.new(MODULE_UTILS_TEXT_DEPRECATION_TEXT)])
      result
    end

    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end
      name = name.strip
      return PluginResult.new(changed: false, failed: true, msg: "name cannot be blank") if name.empty?

      state = @params["state"]? || "present"
      value = @params["value"]?
      if state == "present" && !value
        return PluginResult.new(changed: false, failed: true, msg: "state is present but all of the following are missing: value")
      end
      parsed_value = parse_value(value)
      if state == "present" && parsed_value.empty?
        return PluginResult.new(changed: false, failed: true, msg: "value cannot be blank")
      end

      sysctl_file = @params["sysctl_file"]? || DEFAULT_SYSCTL_FILE
      check_mode = true?(@params["_ansible_check_mode"]?)
      reload = true?(@params["reload"]?, default: true)

      # Real SysctlModule.process() order: read the live value, read the
      # file, decide changed/write_file/set_proc, then (not check mode)
      # set the live value FIRST and the conf file second - so a failed
      # `sysctl -w` fails the task with changed=false and leaves the conf
      # file untouched.
      proc_value = get_token_curr_value(name)

      file_lines = read_lines(sysctl_file).map(&.strip)
      file_values = file_values_from(file_lines)
      fixed_lines = fix_lines(file_lines, name, parsed_value, state)

      changed = false
      write_file = false
      set_proc = false

      fv = file_values[name]?
      if fv.nil? && state == "present"
        changed = true
        write_file = true
      elsif fv.nil? && state == "absent"
        # changed stays false
      elsif !fv.nil? && !fv.empty? && state == "absent"
        changed = true
        write_file = true
      elsif fv != parsed_value
        changed = true
        write_file = true
      elsif reload
        changed = true unless (live = proc_value) && values_is_equal(live, parsed_value)
      end

      if state == "present" && true?(@params["sysctl_set"]?)
        if (live = proc_value)
          unless values_is_equal(live, parsed_value)
            changed = true
            set_proc = true
          end
        else
          changed = true
        end
      end

      unless check_mode
        if set_proc && (failure = set_token_value(name, parsed_value, sysctl_file))
          return failure
        end
        write_lines(sysctl_file, fixed_lines) if write_file
        if changed && reload && (failure = reload_sysctl(sysctl_file))
          return failure
        end
      end

      # Real sysctl.py has exactly one success exit - module.exit_json(changed=result.changed)
      # (sysctl.py:416) - and it echoes neither name nor sysctl_file (round 992001
      # kop_kernel key-order capture: real registers {changed, failed} only).
      PluginResult.new(changed: changed, failed: false)
    end

    # Real _parse_value: booleans become "1"/"0", strings are stripped,
    # nil becomes "".
    private def parse_value(value : String?) : String
      return "" unless value
      lower = value.downcase
      return "1" if {"y", "yes", "on", "1", "t", "true"}.includes?(lower)
      return "0" if {"n", "no", "off", "0", "f", "false"}.includes?(lower)
      expand_whole_u64_float(value.strip)
    end

    # Crystal's YAML parser (and JSON::Any after it) has no unsigned-64
    # integer: a YAML int beyond Int64's range falls back to Float64.
    # That is exactly the scale sysctl tuning roles use
    # (jtprogru.sysctl round 1300003: `kernel.shmall: 18446744073692774399`
    # reached this plugin as the string "1.8446744073692774e+19", and
    # `sysctl -w kernel.shmall=1.84...e+19` fails "Invalid argument"
    # where real Ansible's PyYAML integer becomes plain decimal digits
    # and succeeds). Expand a scientific-notation value that denotes a
    # whole number at or beyond Int64's range into plain digits. Small
    # integral strings ("65535") round-trip unchanged; anything below
    # 2^63 keeps the float rendering a genuine YAML float literal would
    # have ("1e3" stays "1e3", like real's str(float)).
    private def expand_whole_u64_float(value : String) : String
      f = value.to_f64?
      return value if f.nil? || f != f.trunc || f <= Int64::MAX || f > UInt64::MAX
      f.to_u64.to_s
    end

    # Real _values_is_equal: whitespace-split token comparison, order
    # included.
    private def values_is_equal(a : String, b : String) : Bool
      a_tokens = a.split
      b_tokens = b.split
      return false if a_tokens.size != b_tokens.size
      a_tokens.zip(b_tokens).all? { |x, y| x == y }
    end

    # Real read_sysctl_file's parse half: only keys with an "=" count,
    # last occurrence wins (dict overwrite), values stripped.
    private def file_values_from(lines : Array(String)) : Hash(String, String)
      values = Hash(String, String).new
      lines.each do |stripped|
        next if stripped.empty? || stripped.starts_with?('#') || stripped.starts_with?(';') || !stripped.includes?('=')
        key, val = stripped.split('=', 2)
        values[key.strip] = val.strip
      end
      values
    end

    # Real fix_lines, byte for byte: passthrough lines (comments, blanks,
    # no "=") keep their (stripped) content; the first occurrence of each
    # key wins; the managed key is rewritten as "key=value" when present
    # or appended once at the end; state: absent drops it entirely.
    private def fix_lines(lines : Array(String), name : String, parsed_value : String?, state : String) : Array(String)
      checked = [] of String
      fixed = [] of String
      lines.each do |stripped|
        if stripped.empty? || stripped.starts_with?('#') || stripped.starts_with?(';') || !stripped.includes?('=')
          fixed << stripped
          next
        end
        key, val = stripped.split('=', 2)
        key = key.strip
        next if checked.includes?(key)
        checked << key
        if key == name
          fixed << "#{key}=#{parsed_value}" if state == "present"
        else
          fixed << "#{key}=#{val.strip}"
        end
      end
      fixed << "#{name}=#{parsed_value}" if !checked.includes?(name) && state == "present"
      fixed
    end

    # Real get_token_curr_value: `sysctl -e -n <token>` under LANG=C (the
    # stderr must be parseable); a nonzero rc reads as nil (unknown key).
    private def get_token_curr_value(token : String) : String?
      result = remote_exec("LANG=C LC_ALL=C LC_MESSAGES=C sysctl -e -n #{Process.quote(token)}")
      return nil if result[:exit_code] != 0
      result[:stdout]
    end

    # `String#split("\n")` always produces one trailing "" artifact when
    # content ends with "\n" - dropped here so a round-trip read+rewrite
    # doesn't accumulate a spurious blank line each time. Natively,
    # `File.read_lines` (chomp: true) already yields exactly this shape.
    private def read_lines(sysctl_file : String) : Array(String)
      return [] of String unless remote_file_exists?(sysctl_file)

      if local_connection?
        # File.read_lines of an empty file yields [] (matching
        # Ansible's splitlines()), which is slightly more correct than the
        # old shell path's [""] artifact - both are a no-op for the
        # changed-flag, so the only difference is an empty seed file.
        File.read_lines(sysctl_file)
      else
        content = remote_exec("cat #{shell_single_quote(sysctl_file)}")[:stdout]
        lines = content.split("\n")
        lines.pop if !lines.empty? && lines.last.empty? && content.ends_with?("\n")
        lines
      end
    end

    private def write_lines(sysctl_file : String, lines : Array(String)) : Nil
      content = lines.join("\n")
      content += "\n" unless content.empty? || content.ends_with?("\n")

      if local_connection?
        File.write(sysctl_file, content)
      else
        tmp = File.tempname
        File.write(tmp, content)
        remote_upload(tmp, sysctl_file)
        File.delete(tmp)
      end
    end

    # Real set_token_value: `sysctl [-e] -w token="value"` under LANG=C;
    # fails the task (changed stays false) when the rc is nonzero OR the
    # stderr matches Ansible's _stderr_failed regex - sysctl can exit
    # 0 yet still fail to set a value
    # (https://bugzilla.redhat.com/show_bug.cgi?id=1264080).
    # Both this and reload_sysctl's failure are Ansible's plain
    # `fail_json(msg=...)` - msg only, no name/sysctl_file echo.
    private def set_token_value(token : String, value : String, sysctl_file : String) : PluginResult?
      ignore_flag = true?(@params["ignoreerrors"]?) ? "-e " : ""
      # Unquoted, a space-separated value (net.ipv4.ip_local_port_range:
      # "32768 65535") splits into two shell words - sysctl sets only the
      # first and then chokes on the second as a bogus bare key, failing
      # the whole command where Ansible.posix.sysctl's own quoted
      # write succeeds. Found via juju4.harden_sysctl, round 60128.
      result = remote_exec("LANG=C LC_ALL=C LC_MESSAGES=C sysctl #{ignore_flag}-w #{Process.quote(token)}=#{Process.quote(value)}")
      if result[:exit_code] != 0 || stderr_failed?(result[:stderr])
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "setting #{token} failed: #{result[:stdout]}#{result[:stderr]}"
        )
      end
      nil
    end

    # Real _stderr_failed: only these two specific stderr shapes count as
    # a failure behind an rc 0.
    private def stderr_failed?(err : String) : Bool
      !!(err =~ /^sysctl: setting key "[^"]+": (Invalid argument|Read-only file system)$/)
    end

    # Real reload_sysctl: `sysctl [-e] -p <file>` under LANG=C; failure
    # text is "Failed to reload sysctl: <out><err>" - fail_json(msg=...)
    # only, no name/sysctl_file echo (live-verified vs 2.19.11).
    private def reload_sysctl(sysctl_file : String) : PluginResult?
      ignore_flag = true?(@params["ignoreerrors"]?) ? "-e" : ""
      result = remote_exec("LANG=C LC_ALL=C LC_MESSAGES=C sysctl #{ignore_flag} -p #{shell_single_quote(sysctl_file)}")
      if result[:exit_code] != 0 || stderr_failed?(result[:stderr])
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to reload sysctl: #{result[:stdout]}#{result[:stderr]}"
        )
      end
      nil
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::SysctlPlugin.new(config)
plugin.run
