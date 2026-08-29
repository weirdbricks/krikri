#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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

      state = @params["state"]? || "present"
      value = @params["value"]?
      if state == "present" && !value
        return PluginResult.new(changed: false, failed: true, msg: "state is present but all of the following are missing: value")
      end

      sysctl_file = @params["sysctl_file"]? || DEFAULT_SYSCTL_FILE
      check_mode = true?(@params["check_mode"]?)

      lines = read_lines(sysctl_file)
      new_lines = rewrite_lines(lines, name, value, state)
      changed = new_lines != lines

      unless check_mode
        write_lines(sysctl_file, new_lines) if changed

        if state == "present" && true?(@params["sysctl_set"]?)
          # Real ansible.posix.sysctl fails the task when `sysctl -w`
          # itself fails (an invalid/read-only kernel parameter name,
          # for instance) - unless ignoreerrors: is set, which is
          # forwarded to sysctl's own `-e` flag for exactly this. This
          # used to discard apply_kernel_value's result entirely and
          # unconditionally return failed: false regardless - the same
          # "real command failure silently swallowed" shape as
          # apt_repository.cr's own update_cache bug found this round,
          # just in a different plugin.
          kernel_result = apply_kernel_value(name, value)
          if kernel_result[:exit_code] != 0 && !true?(@params["ignoreerrors"]?)
            return PluginResult.new(
              changed: changed,
              failed: true,
              msg: "Failed to set sysctl #{name}: #{kernel_result[:stderr]}",
              name: name,
              sysctl_file: sysctl_file
            )
          end
        end

        reload_sysctl(sysctl_file) if changed && true?(@params["reload"]?, default: true)
      end

      PluginResult.new(changed: changed, failed: false, msg: "", name: name, sysctl_file: sysctl_file)
    end

    # Rewrites `lines` with `name`'s entry set/removed, matching real
    # Ansible's own fix_lines(): comments/blanks pass through untouched,
    # only the first occurrence of a duplicated key is kept, state:
    # absent drops the key's line entirely rather than commenting it.
    private def rewrite_lines(lines : Array(String), name : String, value : String?, state : String) : Array(String)
      seen = Set(String).new
      found = false
      result = [] of String

      lines.each do |line|
        stripped = line.strip
        if stripped.empty? || stripped.starts_with?('#') || stripped.starts_with?(';') || !stripped.includes?('=')
          result << line
          next
        end

        key = stripped.split('=', 2)[0].strip
        next if seen.includes?(key)
        seen.add(key)

        if key == name
          found = true
          result << "#{name}=#{value}" if state == "present"
        else
          result << stripped
        end
      end

      result << "#{name}=#{value}" if !found && state == "present"
      result
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
        content = remote_exec("cat #{sysctl_file}")[:stdout]
        lines = content.split("\n")
        lines.pop if !lines.empty? && lines.last.empty? && content.ends_with?("\n")
        lines
      end
    end

    private def write_lines(sysctl_file : String, lines : Array(String))
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

    private def apply_kernel_value(name : String, value : String?)
      ignore_flag = true?(@params["ignoreerrors"]?) ? "-e " : ""
      remote_exec("sysctl #{ignore_flag}-w #{name}=#{value}")
    end

    private def reload_sysctl(sysctl_file : String)
      ignore_flag = true?(@params["ignoreerrors"]?) ? "-e " : ""
      remote_exec("sysctl #{ignore_flag}-p #{sysctl_file}")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::SysctlPlugin.new(config)
plugin.run
