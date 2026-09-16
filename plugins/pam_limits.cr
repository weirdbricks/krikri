#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

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
    include PluginHelpers::AnsibleArgValidation

    property? check_mode : Bool

    DEFAULT_DEST = "/etc/security/limits.conf"

    # Real argument_spec, declaration order - no aliases.
    SPEC = {
      "domain"     => %w[],
      "limit_type" => %w[],
      "limit_item" => %w[],
      "value"      => %w[],
      "use_max"    => %w[],
      "use_min"    => %w[],
      "backup"     => %w[],
      "dest"       => %w[],
      "comment"    => %w[],
    }

    # Real main()'s own pam_items / pam_types lists - the choices error
    # echoes them in this order (NOT the docstring's order for
    # limit_type, which differs).
    PAM_ITEMS = ["core", "data", "fsize", "memlock", "nofile", "rss", "stack", "cpu", "nproc", "as", "maxlogins", "maxsyslogins", "priority", "locks", "sigpending", "msgqueue", "nice", "rtprio", "chroot"]
    PAM_TYPES = ["soft", "hard", "-"]

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      domain = @params["domain"]
      limit_type = @params["limit_type"]
      limit_item = @params["limit_item"]
      value = @params["value"]
      use_max = true?(@params["use_max"]?)
      use_min = true?(@params["use_min"]?)
      backup = true?(@params["backup"]?)
      comment = @params["comment"]? || ""

      dest = expand_tilde(@params["dest"]? || DEFAULT_DEST)

      # Real main()'s pre-loop body, in its own order: the dest
      # writability check runs BEFORE the use_min/use_max mutual
      # exclusion and the value validation, and a missing dest with a
      # writable parent dir marks changed=true up front (the file gets
      # created even if the entry turns out to be a no-op append).
      changed = false
      does_not_exist = false
      if File.file?(dest)
        unless File.writable?(dest)
          return PluginResult.new(changed: false, failed: true, msg: "#{dest} is not writable. Use sudo")
        end
      else
        dest_dir = File.dirname(dest)
        if File.directory?(dest_dir) && File.writable?(dest_dir)
          does_not_exist = true
          changed = true
        else
          return PluginResult.new(changed: false, failed: true,
            msg: "directory #{dest_dir} is not writable (check presence, access rights, use sudo)")
        end
      end

      if use_max && use_min
        return PluginResult.new(changed: false, failed: true, msg: "Cannot use use_min and use_max at the same time.")
      end

      if err = assert_valid_value(limit_item, value, "")
        return err
      end

      content = File.exists?(dest) ? File.read(dest) : ""

      backupdest = ""
      if backup && File.file?(dest)
        backupdest = backup_local(dest)
      end

      # Transliteration of real pam_limits.py's rewrite loop. Lines keep
      # their newlines (real reads bytes); new_comment persists across
      # iterations exactly like the real module's own variable, including
      # being repopulated from the last seen line's comment when the
      # comment param was omitted, and the "\t#" prefix being folded into
      # it permanently once an entry is written.
      lines = content.lines(chomp: false)
      new_comment = comment
      message = ""
      found = false
      out_lines = [] of String

      lines.each do |line|
        if line.starts_with?("#")
          out_lines << line
          next
        end

        newline = line.gsub(/\s+/, " ").strip
        if newline.empty?
          out_lines << line
          next
        end

        newline = newline.split("#", 2)[0]
        old_comment = line.includes?("#") ? line.split("#", 2)[1] : ""

        newline = newline.rstrip

        new_comment = old_comment if new_comment.empty?

        line_fields = newline.split(" ")
        if line_fields.size != 4
          out_lines << line
          next
        end

        line_domain = line_fields[0]
        line_type = line_fields[1]
        line_item = line_fields[2]
        actual_value = line_fields[3]

        if err = assert_valid_value(line_item, actual_value, "Invalid configuration found in '#{dest}'.")
          return err
        end

        if line_domain == domain && line_type == limit_type && line_item == limit_item
          found = true
          if value == actual_value
            message = line
            out_lines << line
            next
          end

          new_value = value
          if line_type != "nice" && line_type != "priority"
            actual_value_unlimited = ["unlimited", "infinity", "-1"].includes?(actual_value)
            value_unlimited = ["unlimited", "infinity", "-1"].includes?(value)
          else
            actual_value_unlimited = false
            value_unlimited = false
          end

          if use_max
            new_value = if actual_value_unlimited
                          actual_value
                        elsif value_unlimited
                          value
                        else
                          Math.max(value.to_i, actual_value.to_i).to_s
                        end
          end

          if use_min
            new_value = if actual_value_unlimited && value_unlimited
                          actual_value
                        elsif actual_value_unlimited
                          value
                        elsif value_unlimited
                          actual_value
                        else
                          Math.min(value.to_i, actual_value.to_i).to_s
                        end
          end

          if new_value != actual_value
            changed = true
            new_comment = "\t##{new_comment}" unless new_comment.empty?
            new_limit = "#{domain}\t#{limit_type}\t#{limit_item}\t#{new_value}#{new_comment}\n"
            message = new_limit
            out_lines << new_limit
          else
            message = line
            out_lines << line
          end
        else
          out_lines << line
        end
      end

      unless found
        changed = true
        new_comment = "\t##{new_comment}" unless new_comment.empty?
        new_limit = "#{domain}\t#{limit_type}\t#{limit_item}\t#{value}#{new_comment}\n"
        message = new_limit
        out_lines << new_limit
      end

      if changed && !@check_mode
        File.touch(dest) if does_not_exist
        File.write(dest, out_lines.join)
      end

      # Real pam_limits.py's own result shape (verified live against
      # community.general 12.5.0 / ansible-core 2.19): `msg` is the
      # EFFECTIVE limits line (the new entry when changed, the existing
      # matched line when already present - trailing newline included),
      # plus a diff of the whole file (before/after content, always
      # present in the module's own res_args regardless of diff mode -
      # in check mode the after-content is the would-be file content),
      # and NO path echo. Its msg is never empty, so it always appears.
      new_content = out_lines.join
      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: message,
        diff: JSON.parse({before: content, after: new_content}.to_json),
        backup_file: backupdest
      )
      result
    end

    # Real AnsibleModule setup surface: required args (sorted plural
    # wording), limit_type/limit_item choices in main()'s own list
    # order, bool conversion for the three type=bool params, then
    # unsupported params - all BEFORE the dest file is touched.
    private def validate_arguments : PluginResult?
      missing = ["domain", "limit_type", "limit_item", "value"].select { |param| !@params[param]? }
      return missing_required_error(missing) unless missing.empty?

      limit_type = @params["limit_type"]
      return choices_error("limit_type", PAM_TYPES, limit_type) unless PAM_TYPES.includes?(limit_type)

      limit_item = @params["limit_item"]
      return choices_error("limit_item", PAM_ITEMS, limit_item) unless PAM_ITEMS.includes?(limit_item)

      {"use_max", "use_min", "backup"}.each do |param|
        if raw = @params[param]?
          return bool_type_error(param, raw) unless bool_convertible?(raw)
        end
      end

      if unsupported = unsupported_param_keys(@params, SPEC)
        unless unsupported.empty?
          return unsupported_params_error("community.general.pam_limits", unsupported, SPEC)
        end
      end

      nil
    end

    # Real _assert_is_valid_value: nice/priority take a Python int() in
    # -20..19; everything else must be unlimited/infinity/-1 or a digit
    # string. prefix="" for the module's own params, and the real
    # f-string always puts a space after it (so the no-prefix message
    # starts with one).
    private def assert_valid_value(item : String, value : String, prefix : String) : PluginResult?
      if item == "nice" || item == "priority"
        parsed = value.to_i? if value.matches?(/\A[+-]?\d+\z/)
        valid = parsed ? parsed >= -20 && parsed <= 19 : false
        unless valid
          return PluginResult.new(changed: false, failed: true,
            msg: "#{prefix} Value of '#{value}' for item '#{item}' is invalid. " \
                 "Value must be a number in the range -20 to 19 inclusive. " \
                 "Refer to the limits.conf(5) manual pages for more details.")
        end
      elsif !(["unlimited", "infinity", "-1"].includes?(value) || value.matches?(/\A\d+\z/))
        return PluginResult.new(changed: false, failed: true,
          msg: "#{prefix} Value of '#{value}' for item '#{item}' is invalid. " \
               "Value must either be 'unlimited', 'infinity' or -1, all of " \
               "which indicate no limit, or a limit of 0 or larger. Refer to the limits.conf(5) manual pages for " \
               "more details.")
      end
      nil
    end

    # Naming matches real ansible's backup_local() helper: <path>.
    # <file-owner-uid>.<YYYY-MM-DD@HH:MM:SS>~ (same convention the pamd
    # plugin uses).
    private def backup_local(path : String) : String
      timestamp = Time.local.to_s("%Y-%m-%d@%H:%M:%S")
      backup_path = "#{path}.#{Process.pid}.#{timestamp}~"
      File.copy(path, backup_path)
      backup_path
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PamLimitsPlugin.new(config)
plugin.run
