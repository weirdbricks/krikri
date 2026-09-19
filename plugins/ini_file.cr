#!/usr/bin/env crystal

require "json"
require "file_utils"
require "../src/krikri/base_plugin"

module Krikri
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
      values_param = @params["values"]?
      state = @params["state"]? || "present"
      create = @params["create"]? ? true?(@params["create"]) : true
      exclusive = @params["exclusive"]? ? true?(@params["exclusive"]) : true
      no_extra_spaces = true?(@params["no_extra_spaces"]?)
      check_mode = true?(@params["_ansible_check_mode"]?)

      # Real ini_file accepts either `value` (a single string, sugar for a
      # one-element list) or `values` (the list form), never both - its
      # argspec declares mutually_exclusive=[['value', 'values']] and
      # ansible-core rejects the combination with the standard mutual
      # exclusion failure (same wording blockinfile.cr already uses).
      if value && values_param
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: value|values")
      end

      # RedHatOfficial.rhel9_cui (round900703) ships tasks passing `values:`
      # as a list of plain strings (two ExecStart= lines under [Service]) -
      # this engine only ever read `value:` and silently ignored `values:`,
      # failing outright with the value-required error. Both params funnel
      # into one internal list from here on, mirroring real do_ini's own
      # `if value is not None: values = [value]` merge.
      values = values_param ? parse_values_list(values_param) : (value ? [value] : nil)

      if err = validate_inputs(path, section, option, values, state, create)
        return err
      end

      original = File.exists?(path) ? File.read(path) : ""
      lines = initial_lines(original)

      new_lines, changed, branch_msg = apply(lines, section, option, values, state, create, exclusive, no_extra_spaces)

      finish_execute(path, original, new_lines, changed, branch_msg, check_mode)
    end

    private def finish_execute(path : String, original : String, new_lines : Array(String),
                               changed : Bool, branch_msg : String?, check_mode : Bool) : PluginResult
      backup_file = maybe_backup(path, changed, true?(@params["backup"]?), check_mode)

      new_content = new_content_of(new_lines)

      # Real ini_file ALWAYS carries a diff dict in its result, with
      # "<path> (content)" before/after headers (live-verified against
      # ansible-core 2.19.11) and before/after content filled only in
      # --diff mode - so an unchanged non-diff-mode result still carries
      # the (empty-content) dict rather than omitting the key.
      diff = if @diff_mode
               generate_unified_diff(original, new_content, "#{path} (content)", "#{path} (content)")
             else
               generate_unified_diff("", "", "#{path} (content)", "#{path} (content)")
             end

      write_new_content(path, new_content) if changed && !check_mode

      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: branch_msg || "OK",
        diff: diff,
        path: path
      )
      # Real module includes backup_file only when a backup was actually
      # made (its None default is dropped by exit_json).
      result.extra["backup_file"] = JSON::Any.new(backup_file) unless backup_file.empty?
      result
    end

    private def initial_lines(original : String) : Array(String)
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
      lines = split_lines(original)
      lines = [""] of String if lines.empty?
      lines
    end

    private def new_content_of(new_lines : Array(String)) : String
      new_content = new_lines.join("\n")
      new_content += "\n" if new_lines.size > 0
      new_content
    end

    # `values` arrives as the JSON-stringified list form (params are
    # flattened to strings by BasePlugin); same parse convention as
    # rhsm_repository.cr's name list. A non-list or malformed value is
    # reported as nil so validate_inputs produces the value-required
    # failure rather than a raw JSON parse crash.
    private def parse_values_list(raw : String) : Array(String)?
      parsed = JSON.parse(raw)
      return nil unless parsed.as_a?
      parsed.as_a.map(&.as_s)
    rescue
      nil
    end

    private def validate_inputs(path : String, section : String?, option : String?, values : Array(String)?,
                                state : String, create : Bool) : PluginResult?
      # Real main(): `if state == 'present' and not allow_no_value and
      # value is None and not values` - an EMPTY values list fails the
      # same required check as an absent one (allow_no_value is not
      # supported here at all, so the condition reduces to this).
      if state == "present" && option && (values.nil? || values.try(&.empty?))
        return PluginResult.new(changed: false, failed: true, msg: "Value must be set when state=present and option is defined")
      end

      unless File.exists?(path) || create
        return PluginResult.new(changed: false, failed: true, msg: "Destination #{path} does not exist!")
      end

      if section && !find_section_header(read_lines(path), section) && !create && state == "present"
        return PluginResult.new(changed: false, failed: true, msg: "Section [#{section}] does not exist in #{path}")
      end

      nil
    end

    private def maybe_backup(path : String, changed : Bool, backup : Bool, check_mode : Bool) : String
      if changed && backup && File.exists?(path) && !check_mode
        write_backup(path)
      else
        ""
      end
    end

    private def write_new_content(path : String, new_content : String) : Nil
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write(path, new_content)
      apply_mode(path)
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
    # krikri-playbook always appended a brand-new active line at the
    # end of the section instead of uncommenting the existing one in
    # place, unlike real Ansible. Found benchmarking robertdebock.
    # systemd's own journald.conf `LineMax` setting.
    #
    # With `active_only` set, the comment marker is disallowed entirely,
    # matching real Ansible's own `match_active_opt`: real Ansible's
    # state=absent branch hard-codes `match_active_opt` and ignores
    # `modify_inactive_option` completely, so a commented-out line is
    # never a match for removal (adfinis-sygroup.systemd_journald's
    # `Storage: absent` task on a fresh journald.conf whose `#Storage=auto`
    # is still commented out - krikri-playbook used to delete the comment
    # and report changed where real Ansible reports ok).
    private def option_line_index?(line : String, option : String, active_only : Bool = false) : Bool
      match = if active_only
                line.match(/^\s*([^=;#\s][^=]*?)\s*=/)
              else
                line.match(/^\s*[#;]?\s*([^=;#\s][^=]*?)\s*=/)
              end
      return false unless match
      match[1].strip == option
    end

    private def format_option(option : String, value : String, no_extra_spaces : Bool) : String
      no_extra_spaces ? "#{option}=#{value}" : "#{option} = #{value}"
    end

    private def apply(lines : Array(String), section : String?, option : String?, values : Array(String)?,
                      state : String, create : Bool, exclusive : Bool, no_extra_spaces : Bool) : {Array(String), Bool, String?}
      new_lines = lines.dup
      changed = false
      msg = nil

      header_idx, section_added, abort = prepare_section(new_lines, section, state)
      return {new_lines, false, nil} if abort

      block_start = header_idx ? header_idx + 1 : 0
      block_end = find_block_end(new_lines, block_start)

      if option
        option_changed, option_msg = apply_option(new_lines, option, values, state, block_start, block_end, exclusive, no_extra_spaces)
        if option_changed
          changed = true
          msg = option_msg
        end
      elsif state == "absent" && header_idx
        (header_idx...block_end).to_a.reverse_each { |i| new_lines.delete_at(i) }
        changed = true
        msg = "section removed"
      end

      # Real do_ini overrides the msg when the section itself was newly
      # appended (its `not within_section` branch): "section and option
      # added" when an option line goes in with it, "only section added"
      # otherwise.
      msg = option ? "section and option added" : "only section added" if section_added

      {new_lines, changed, msg}
    end

    # Locates (or appends, state=present only) the section header.
    # Returns {header_idx, section_added, abort} - abort true means the
    # real module's absent-on-missing-section no-op and nothing further
    # should run.
    private def prepare_section(new_lines : Array(String), section : String?, state : String) : {Int32?, Bool, Bool}
      header_idx = section ? find_section_header(new_lines, section) : nil
      if section && !header_idx
        return {nil, false, true} if state == "absent"
        return {append_section(new_lines, section), true, false}
      end
      {header_idx, false, false}
    end

    private def append_section(new_lines : Array(String), section : String) : Int32
      # Real do_ini appends a new section header DIRECTLY - no blank-line
      # separator (`ini_lines.append(f"[{section}]\n")`). The only blank
      # line real ever produces is the empty-file seed in initial_lines,
      # which is already in `new_lines` by the time a second section is
      # appended; adding another one here put a spurious blank line
      # between the previous section's last option and every newly
      # appended `[section]` header (caught by the podman-diff harness's
      # byte-for-byte `cat` of the final file).
      new_lines << "[#{section}]"
      new_lines.size - 1
    end

    # Returns {changed, msg} - real do_ini's per-branch msg strings
    # (live-verified against ansible-core 2.19.11): "option added" when
    # the option line is newly inserted, "option changed" for an
    # in-place rewrite, a dedup removal, or a state=absent removal,
    # nil ("OK" upstream) when nothing changed.
    #
    # `values` is the merged list form of real do_ini's own value/values
    # params (a singular `value:` enters here as a one-element list, and
    # the list is deduped like do_ini's values_unique). The multi-value
    # algorithm follows real do_ini's own four documented steps for
    # state=present (round900703 RedHatOfficial.rhel9_cui's ExecStart
    # values list): 1) claim existing lines already holding one of the
    # requested values, 2) with exclusive (the default) overwrite
    # remaining unclaimed option lines with still-unplaced values and
    # delete whatever option lines are left over, 3) insert unplaced
    # values at the end of the section, 4) changed if anything was
    # touched. Without exclusive the legacy single-value behavior is
    # kept instead: rewrite unclaimed matching lines in place with the
    # unplaced values, never delete, insert only what no existing line
    # could absorb.
    private def apply_option(new_lines : Array(String), option : String, values : Array(String)?,
                             state : String, block_start : Int32, block_end : Int32,
                             exclusive : Bool, no_extra_spaces : Bool) : {Bool, String?}
      # state=absent only ever matches ACTIVE (uncommented) option lines,
      # per real Ansible's hard-coded match_active_opt in its absent branch.
      active_only = state == "absent"
      matches = (block_start...block_end).select { |i| option_line_index?(new_lines[i], option, active_only) }

      if state == "present"
        # do_ini dedupes the values list (values_unique) before any of
        # its matching passes run.
        remaining = dedupe_values(values || [] of String)
        claimed = Set(Int32).new

        changed = claim_requested_values(new_lines, option, matches, remaining, claimed, no_extra_spaces)
        changed = replace_unclaimed_lines(new_lines, option, matches, remaining, claimed, exclusive, no_extra_spaces) || changed

        # Insertion pass - values no existing line could claim go in at
        # the end of the section, i.e. after its last non-blank,
        # non-comment line (do_ini searches backwards for exactly that
        # point), kept in original list order.
        unless remaining.empty?
          insert_at = section_insert_index(new_lines, block_start, block_end)
          remaining.reverse_each do |value|
            new_lines.insert(insert_at, format_option(option, value, no_extra_spaces))
          end
          return {true, "option added"}
        end

        return {true, "option changed"} if changed
      else
        unless matches.empty?
          matches.reverse_each { |i| new_lines.delete_at(i) }
          return {true, "option changed"}
        end
      end

      {false, nil}
    end

    # Claim pass - an existing line whose parsed value is still requested
    # is rewritten with its own (canonical) value in place and that value
    # is consumed, exactly like do_ini's first loop with
    # `values.remove(matched_value)`.
    private def claim_requested_values(new_lines : Array(String), option : String, matches : Array(Int32),
                                       remaining : Array(String), claimed : Set(Int32), no_extra_spaces : Bool) : Bool
      changed = false
      matches.each do |i|
        existing = option_line_value(new_lines[i], option)
        next unless existing && remaining.includes?(existing)
        changed = rewrite_option_line(new_lines, i, option, existing, no_extra_spaces) || changed
        remaining.delete(existing)
        claimed << i
      end
      changed
    end

    # Exclusive: stale option lines (value not requested) absorb the
    # still-unplaced values in list order - do_ini's exclusive
    # `values.pop(0)` replacement - and whatever option lines remain
    # unclaimed after that carry values not requested anymore and are
    # deleted. Non-exclusive keeps this engine's historical semantics for
    # a singular value (rewrite the first matching line in place, never
    # delete duplicates) generalized to the list.
    private def replace_unclaimed_lines(new_lines : Array(String), option : String, matches : Array(Int32),
                                        remaining : Array(String), claimed : Set(Int32),
                                        exclusive : Bool, no_extra_spaces : Bool) : Bool
      changed = false
      matches.each do |i|
        next if claimed.includes?(i)
        break if remaining.empty?
        changed = rewrite_option_line(new_lines, i, option, remaining.shift, no_extra_spaces) || changed
        claimed << i if exclusive
      end
      if exclusive
        matches.reverse_each do |i|
          next if claimed.includes?(i)
          new_lines.delete_at(i)
          changed = true
        end
      end
      changed
    end

    private def rewrite_option_line(new_lines : Array(String), index : Int32, option : String,
                                    value : String, no_extra_spaces : Bool) : Bool
      formatted = format_option(option, value, no_extra_spaces)
      return false if new_lines[index] == formatted
      new_lines[index] = formatted
      true
    end

    private def dedupe_values(values : Array(String)) : Array(String)
      unique = [] of String
      values.each { |v| unique << v unless unique.includes?(v) }
      unique
    end

    # Extracts the value part of a matched option line the way real
    # match_opt's group(8) does: everything after `=` with the spaces and
    # tabs immediately following it consumed, trailing content (including
    # trailing whitespace) kept verbatim.
    private def option_line_value(line : String, option : String) : String?
      match = line.match(/^[ \t]*[#;]?[ \t]*#{Regex.escape(option)}[ \t]*=(.*)$/)
      return nil unless match
      match[1].lstrip(" \t")
    end

    # Real do_ini inserts new option lines after the section's last
    # non-blank, non-comment line (its non_blank_non_comment_pattern
    # backward scan), NOT at the raw end of the section - trailing blank
    # lines between this section and the next `[header]` stay after the
    # inserted options. The section header itself always terminates the
    # backward scan, so block_start is the fallback.
    private def section_insert_index(lines : Array(String), block_start : Int32, block_end : Int32) : Int32
      (block_start...block_end).reverse_each do |i|
        stripped = lines[i].strip
        return i + 1 unless stripped.empty? || stripped.starts_with?('#') || stripped.starts_with?(';')
      end
      block_start
    end

    private def write_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_file = "#{path}.#{Process.pid}.#{timestamp}~"
      File.copy(path, backup_file)
      backup_file
    end

    private def apply_mode(path : String) : Nil
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
plugin = Krikri::IniFilePlugin.new(config)
plugin.run
