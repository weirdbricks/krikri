#!/usr/bin/env crystal

require "json"
require "file_utils"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # ini_file plugin - manages [section]/option=value entries in an INI-style
  # config file. Compatible with community.general.ini_file's common shape
  # (path/dest, section, option, value, state, create, exclusive,
  # no_extra_spaces, backup, mode).
  class IniFilePlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]? || @params["dest"]?
      return missing_param("path") unless path
      path = expand_tilde(path)

      section = @params["section"]?
      option = @params["option"]?
      value = @params["value"]?
      state = @params["state"]? || "present"
      create = @params["create"]? ? is_true?(@params["create"]) : true
      exclusive = @params["exclusive"]? ? is_true?(@params["exclusive"]) : true
      no_extra_spaces = is_true?(@params["no_extra_spaces"]?)
      backup = is_true?(@params["backup"]?)
      check_mode = is_true?(@params["check_mode"]?)

      if state == "present" && option && !value
        return PluginResult.new(changed: false, failed: true, msg: "Value must be set when state=present and option is defined")
      end

      unless File.exists?(path) || create
        return PluginResult.new(changed: false, failed: true, msg: "Destination #{path} does not exist!")
      end

      if section && !find_section_header(read_lines(path), section) && !create && state == "present"
        return PluginResult.new(changed: false, failed: true, msg: "Section [#{section}] does not exist in #{path}")
      end

      original = File.exists?(path) ? File.read(path) : ""
      lines = split_lines(original)
      # Real Ansible's own ini_file module force-seeds a single blank line
      # (`if not ini_lines: ini_lines.append("\n")`) whenever the starting
      # line list is empty - a brand-new file, or an existing-but-0-byte
      # one - before any section/option insertion logic runs, so a freshly
      # created config always gets exactly one leading blank line before
      # its first `[section]` header. This plugin previously started from
      # a genuinely empty array in that case, producing no leading blank
      # line at all - a real, silent byte-for-byte divergence from real
      # Ansible's output (not a crash) found benchmarking robertdebock.
      # python_pip's own `Configure pip proxy`/`Trust hosts` tasks writing
      # a brand-new `/etc/pip.conf`.
      lines = [""] of String if lines.empty?

      new_lines, changed = apply(lines, section, option, value, state, create, exclusive, no_extra_spaces)

      backup_file = ""
      if changed && backup && File.exists?(path) && !check_mode
        backup_file = write_backup(path)
      end

      new_content = new_lines.join("\n")
      new_content += "\n" if new_lines.size > 0

      diff = generate_unified_diff(original, new_content, path, path) if changed && @diff_mode

      if changed && !check_mode
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(path, new_content)
        apply_mode(path)
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "option changed" : "OK",
        diff: diff,
        path: path,
        backup_file: backup_file
      )
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end

    private def read_lines(path : String) : Array(String)
      File.exists?(path) ? split_lines(File.read(path)) : [] of String
    end

    private def split_lines(content : String) : Array(String)
      lines = content.split("\n")
      lines.pop if lines.size > 0 && lines.last.empty?
      lines
    end

    private def find_section_header(lines : Array(String), section : String) : Int32?
      target = "[#{section}]"
      lines.each_with_index do |line, idx|
        return idx if line.strip == target
      end
      nil
    end

    private def section_header?(line : String) : Bool
      stripped = line.strip
      stripped.starts_with?('[') && stripped.ends_with?(']')
    end

    private def find_block_end(lines : Array(String), block_start : Int32) : Int32
      (block_start...lines.size).each do |i|
        return i if section_header?(lines[i])
      end
      lines.size
    end

    # Matches option lines the same way real Ansible's own `match_opt`
    # does: an OPTIONAL leading `#`/`;` comment marker is allowed before
    # the option name, since `modify_inactive_option` (default `true`)
    # means a commented-out `#option=value` line counts as a match and
    # gets uncommented/replaced in place, not treated as absent. Only
    # bare-name matching used to look at active (non-commented) lines
    # at all - `#LineMax=48K` never matched `option: LineMax`, so
    # `matches.empty?` was always true for a role that ships its config
    # template with every option pre-listed but commented out (very
    # common, e.g. journald.conf/logind.conf's own upstream defaults) -
    # crystal-ansible always appended a brand-new active line at the
    # end of the section instead of uncommenting the existing one in
    # place, unlike real Ansible. Found benchmarking robertdebock.
    # systemd's own journald.conf `LineMax` setting.
    private def option_line_index?(line : String, option : String) : Bool
      match = line.match(/^\s*[#;]?\s*([^=;#\s][^=]*?)\s*=/)
      return false unless match
      match[1].strip == option
    end

    private def format_option(option : String, value : String, no_extra_spaces : Bool) : String
      no_extra_spaces ? "#{option}=#{value}" : "#{option} = #{value}"
    end

    private def apply(lines : Array(String), section : String?, option : String?, value : String?,
                      state : String, create : Bool, exclusive : Bool, no_extra_spaces : Bool) : {Array(String), Bool}
      new_lines = lines.dup
      changed = false

      header_idx = section ? find_section_header(new_lines, section) : nil

      if section && !header_idx
        return {new_lines, false} if state == "absent"

        new_lines << "" unless new_lines.empty? || new_lines.last.strip.empty?
        new_lines << "[#{section}]"
        header_idx = new_lines.size - 1
        changed = true
      end

      block_start = header_idx ? header_idx + 1 : 0
      block_end = find_block_end(new_lines, block_start)

      if option
        matches = (block_start...block_end).select { |i| option_line_index?(new_lines[i], option) }

        if state == "present"
          formatted = format_option(option, value.not_nil!, no_extra_spaces)

          if matches.empty?
            new_lines.insert(block_end, formatted)
            changed = true
          else
            first = matches.first
            if new_lines[first] != formatted
              new_lines[first] = formatted
              changed = true
            end

            if exclusive && matches.size > 1
              matches[1..].reverse_each do |i|
                new_lines.delete_at(i)
                changed = true
              end
            end
          end
        else
          unless matches.empty?
            matches.reverse_each { |i| new_lines.delete_at(i) }
            changed = true
          end
        end
      elsif state == "absent" && header_idx
        (header_idx...block_end).to_a.reverse_each { |i| new_lines.delete_at(i) }
        changed = true
      end

      {new_lines, changed}
    end

    private def write_backup(path : String) : String
      timestamp = Time.local.to_s("%Y%m%d-%H%M%S")
      backup_file = "#{path}.#{timestamp}.bak"
      File.copy(path, backup_file)
      backup_file
    end

    private def apply_mode(path : String)
      if mode = @params["mode"]?
        begin
          # Real Ansible parses ANY all-digit mode string as octal,
          # leading zero or not. See template.cr's identical fix (round
          # 40, robertdebock.redis) for the full story.
          if mode =~ /\A0?[0-7]{3,4}\z/
            File.chmod(path, mode.to_i(8))
          end
        rescue
        end
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::IniFilePlugin.new(config)
plugin.run
