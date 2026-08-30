#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # PamLimits Plugin - Manage user PAM limits entries (limits.conf /
  # limits.d files), matching community.general.pam_limits.
  #
  # Parameters:
  #   domain: user, group (prefixed with @), *, or a range
  #   limit_type: hard, soft, or -
  #   limit_item: core, nproc, nofile, data, fsize, ...
  #   value: the limit value
  #   comment (optional): a trailing `\t#comment` on the entry's own line
  #     (matching real pam_limits.py exactly - NOT a separate line above
  #     it, and NOT applied when an existing matching entry's value is
  #     unchanged, same as real Ansible's own idempotency check).
  #   dest (optional): target file (defaults to /etc/security/limits.conf,
  #     but dev-sec os_hardening writes to /etc/security/limits.d/...).
  #   check_mode: dry-run
  #
  # A matching existing entry (same domain/type/item) is updated in place
  # (preserving its own existing comment unless a new one is given);
  # otherwise a brand new entry is always appended at the true end of the
  # file - real Ansible's own module has no special-casing for a `# End
  # of file` marker or any other comment line anywhere in the file, it
  # just copies every existing line through unchanged and appends after.
  # Idempotent: no write when the exact entry (domain/type/item/value) is
  # already present.
  class PamLimitsPlugin < BasePlugin
    property? check_mode : Bool

    DEFAULT_DEST = "/etc/security/limits.conf"

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
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

      # Find an existing entry with the same domain/type/item, and its
      # own trailing `#comment` (if any) - real Ansible's own pam_limits
      # module keeps a matched line's existing comment untouched when no
      # new `comment:` param is given, only overwriting it when one is.
      lines = content.lines(chomp: false)
      index = nil
      old_comment = nil
      lines.each_with_index do |line, i|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#")
        before_comment, _, after_hash = stripped.partition('#')
        fields = before_comment.strip.split(/\s+/)
        next unless fields.size >= 4
        if fields[0] == domain && fields[1] == limit_type && fields[2] == limit_item
          index = i
          old_comment = after_hash.empty? ? nil : after_hash
          break
        end
      end

      changed = false

      if index
        existing = lines[index].strip.partition('#')[0].strip.split(/\s+/)
        # Exact same domain/type/item/value already present -> no change
        # (real Ansible's own idempotency check is value-only here - a
        # comment-only change to an otherwise-matching line is NOT
        # applied, matching pam_limits.py's own `if value ==
        # actual_value: ... continue` with no comment comparison at all).
        same = existing.size >= 4 &&
               existing[0] == domain && existing[1] == limit_type &&
               existing[2] == limit_item && existing[3] == value
        unless same
          changed = true
          unless @check_mode
            effective_comment = comment || old_comment
            entry_line = build_entry(domain, limit_type, limit_item, value, effective_comment)
            indent = lines[index][0, lines[index].size - lines[index].lstrip.size]
            lines[index] = "#{indent}#{entry_line}"
          end
        end
      else
        changed = true
        unless @check_mode
          # Real Ansible's own module has no special-casing for a `# End
          # of file` marker (or any other comment line) anywhere in the
          # file - it copies every existing line through unchanged and
          # only ever appends the new entry after the whole file,
          # regardless of what the last lines say. This plugin
          # previously inserted BEFORE that marker instead, an invented
          # behavior not in the real module at all.
          entry_line = build_entry(domain, limit_type, limit_item, value, comment)
          # A missing trailing newline on the file's current last line
          # would otherwise run straight into the new entry on the same
          # line.
          lines[-1] = "#{lines[-1]}\n" if !lines.empty? && !lines.last.ends_with?("\n")
          lines << entry_line
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

    # Matches real pam_limits.py's own `f"{domain}\t{limit_type}\t
    # {limit_item}\t{new_value}{new_comment}\n"` exactly - a comment, if
    # any, is a trailing `\t#comment` on the SAME line, not a separate
    # line above the entry.
    private def build_entry(domain : String?, limit_type : String?, limit_item : String?, value : String?, comment : String? = nil) : String
      line = [domain, limit_type, limit_item, value].compact.join("\t")
      line += "\t##{comment}" if comment
      "#{line}\n"
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PamLimitsPlugin.new(config)
plugin.run
