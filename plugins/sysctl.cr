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
  #   file; this needs root/appropriate capabilities the same way real
  #   Ansible's does)
  # - reload: run `sysctl -p <sysctl_file>` to apply the file's contents
  #   to the running kernel when the file changed (default true, matching
  #   real Ansible's default - also needs root/capabilities for real)
  # - ignoreerrors: pass -e to the underlying sysctl command
  # - check_mode: report what would change without writing anything or
  #   touching the running kernel
  #
  # File format and rewrite logic verified by reading the real
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

      PluginResult.new(changed: changed, failed: false, msg: "", name: name, sysctl_file: sysctl_file)
    end

    # Real _parse_value: booleans become "1"/"0", strings are stripped,
    # nil becomes "".
    private def parse_value(value : String?) : String
      return "" unless value
      lower = value.downcase
      return "1" if {"y", "yes", "on", "1", "t", "true"}.includes?(lower)
      return "0" if {"n", "no", "off", "0", "f", "false"}.includes?(lower)
      value.strip
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
        # File.read_lines of an empty file yields [] (matching real
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
    # stderr matches real Ansible's _stderr_failed regex - sysctl can exit
    # 0 yet still fail to set a value
    # (https://bugzilla.redhat.com/show_bug.cgi?id=1264080).
    private def set_token_value(token : String, value : String, sysctl_file : String) : PluginResult?
      ignore_flag = true?(@params["ignoreerrors"]?) ? "-e " : ""
      # Unquoted, a space-separated value (net.ipv4.ip_local_port_range:
      # "32768 65535") splits into two shell words - sysctl sets only the
      # first and then chokes on the second as a bogus bare key, failing
      # the whole command where real ansible.posix.sysctl's own quoted
      # write succeeds. Found via juju4.harden_sysctl, round 60128.
      result = remote_exec("LANG=C LC_ALL=C LC_MESSAGES=C sysctl #{ignore_flag}-w #{Process.quote(token)}=#{Process.quote(value)}")
      if result[:exit_code] != 0 || stderr_failed?(result[:stderr])
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "setting #{token} failed: #{result[:stdout]}#{result[:stderr]}",
          name: token,
          sysctl_file: sysctl_file
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
    # text is "Failed to reload sysctl: <out><err>".
    private def reload_sysctl(sysctl_file : String) : PluginResult?
      ignore_flag = true?(@params["ignoreerrors"]?) ? "-e" : ""
      result = remote_exec("LANG=C LC_ALL=C LC_MESSAGES=C sysctl #{ignore_flag} -p #{shell_single_quote(sysctl_file)}")
      if result[:exit_code] != 0 || stderr_failed?(result[:stderr])
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to reload sysctl: #{result[:stdout]}#{result[:stderr]}",
          name: @params["name"]?,
          sysctl_file: sysctl_file
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
