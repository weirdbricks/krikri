#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # PamLimits Plugin - Manage user PAM limits entries (limits.conf /
  # limits.d files), matching community.general.pam_limits.
  #
  # Parameters:
  #   domain: user, group (prefixed with @), *, or a range
  #   limit_type: hard, soft, or -
  #   limit_item: core, nproc, nofile, data, fsize, ...
  #   value: the limit value
  #   comment (optional): a comment to attach above the entry
  #   dest (optional): target file (defaults to /etc/security/limits.conf,
  #     but dev-sec os_hardening writes to /etc/security/limits.d/...).
  #   check_mode: dry-run
  #
  # A matching existing entry (same domain/type/item) is updated in place;
  # otherwise the line is appended near the `# End of file` marker if one
  # exists, else at the end. Idempotent: no write when the exact entry is
  # already present.
  class PamLimitsPlugin < BasePlugin
    property check_mode : Bool

    DEFAULT_DEST = "/etc/security/limits.conf"

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      domain = @params["domain"]?
      limit_type = @params["limit_type"]?
      limit_item = @params["limit_item"]?
      value = @params["value"]?

      missing = [] of String
      missing << "domain" unless domain
      missing << "limit_type" unless limit_type
      missing << "limit_item" unless limit_item
      missing << "value" unless value

      unless missing.empty?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: #{missing.join(", ")}"
        )
      end

      dest = expand_tilde(@params["dest"]? || DEFAULT_DEST)

      # Comments attached above the entry.
      comment = @params["comment"]?
      comment = comment.strip if comment
      comment = nil if comment && comment.empty?

      begin
        content = File.exists?(dest) ? File.read(dest) : ""
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read #{dest}: #{ex.message}"
        )
      end

      entry_line = build_entry(domain, limit_type, limit_item, value)

      # Find an existing entry with the same domain/type/item (ignoring
      # wholesale comment handling - a comment change alone is a change).
      lines = content.lines(chomp: false)
      index = nil
      lines.each_with_index do |line, i|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#")
        fields = stripped.split(/\s+/)
        next unless fields.size >= 4
        if fields[0] == domain && fields[1] == limit_type && fields[2] == limit_item
          index = i
          break
        end
      end

      changed = false

      if index
        existing = lines[index].strip.split(/\s+/)
        # Exact same domain/type/item/value already present -> no change.
        same = existing.size >= 4 &&
               existing[0] == domain && existing[1] == limit_type &&
               existing[2] == limit_item && existing[3] == value
        unless same
          changed = true
          if @check_mode
            # predict only
          else
            indent = lines[index][0, lines[index].size - lines[index].lstrip.size]
            lines[index] = "#{indent}#{entry_line}"
          end
        end
      else
        changed = true
        if @check_mode
          # predict only
        else
          # Find `# End of file` marker to insert before it, else append.
          eof_idx = lines.index { |line| line.strip == "# End of file" }
          new_lines = comment ? ["", "# #{comment}", entry_line] : [entry_line]
          if eof_idx
            insert_lines(lines, eof_idx, new_lines)
          else
            lines << (lines.empty? ? entry_line : "#{entry_line}\n")
          end
        end
      end

      if changed && !@check_mode
        begin
          File.write(dest, lines.join)
        rescue ex
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to write #{dest}: #{ex.message}"
          )
        end
      end

      msg = changed ? "Added or updated limit entry" : "Entry already present"
      msg += " (check mode)" if @check_mode && changed

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg,
        path: dest
      )
    end

    private def build_entry(domain : String?, limit_type : String?, limit_item : String?, value : String?) : String
      [domain, limit_type, limit_item, value].compact.join("\t")
    end

    # Insert *to_insert* into *lines* at *index* (before the existing line
    # at that position), preserving a trailing newline on the final written
    # line when the file wasn't empty.
    private def insert_lines(lines : Array(String), index : Int32, to_insert : Array(String)) : Nil
      inserted = to_insert.map { |line| line.ends_with?("\n") ? line : "#{line}\n" }
      splice = lines[0, index] + inserted + lines[index..]
      lines.clear
      lines.concat(splice)
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::PamLimitsPlugin.new(config)
plugin.run
