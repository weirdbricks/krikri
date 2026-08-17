#!/usr/bin/env crystal

require "json"
require "file_utils"
require "system/user"
require "system/group"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/line_editor"

module CrystalPlay
  # Lineinfile plugin - manages a single line in a text file
  # Compatible with Ansible's ansible.builtin.lineinfile module
  #
  # Parameters:
  #   path (required, aliases: dest, name - matches real Ansible's own
  #     argument_spec, where `dest:` is the long-standing legacy alias
  #     most existing playbooks/roles still write): File to edit
  #   line: Line content (required for state: present, unless backrefs/regexp-only removal)
  #   regexp: Pattern used to find the line to replace/remove
  #   state: present (default) or absent
  #   create: Create the file if it doesn't exist (default: no)
  #   backup: Write a timestamped backup before changing the file (default: no)
  #   insertafter / insertbefore: EOF/BOF/END/BEGIN or a regexp
  #   backrefs: Substitute regexp match groups into `line` instead of replacing it wholesale
  class LineInFilePlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]? || @params["dest"]? || @params["name"]?
      return missing_param("path") unless path
      path = expand_tilde(path)

      line = @params["line"]?
      regexp = @params["regexp"]?
      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      if error = validate(state, line, regexp)
        return error
      end

      # `state: absent` on a file that doesn't exist at all is a real-
      # Ansible no-op ("file not present", changed: false) - there's
      # nothing to remove a line *from*. Only `state: present` (or an
      # explicit `create: true`) needs the file to actually exist.
      # Found via konstruktoid-hardening's "Clean cron and at" task,
      # `state: absent` on /etc/at.allow/cron.allow, neither of which
      # exist on a stock image - failed outright instead of no-op'ing.
      if state == "absent" && !File.exists?(path) && !is_true?(@params["create"]?)
        return PluginResult.new(changed: false, failed: false, msg: "file not present")
      end

      being_created, error = ensure_file_exists(path, is_true?(@params["create"]?), check_mode)
      return error if error

      apply(path, state, line, regexp, being_created, check_mode)
    end

    # Parameter validation shared by both states.
    private def validate(state : String, line : String?, regexp : String?) : PluginResult?
      if state == "present" && !line
        return PluginResult.new(changed: false, failed: true, msg: "line parameter required when state=present")
      end

      if state == "absent" && !regexp && !line
        return PluginResult.new(changed: false, failed: true, msg: "regexp or line parameter required when state=absent")
      end

      nil
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end

    # Returns {being_created, error}. Creates an empty file (unless
    # check_mode) when it's missing and `create:` was requested.
    private def ensure_file_exists(path : String, create : Bool, check_mode : Bool) : {Bool, PluginResult?}
      return {false, nil} if File.exists?(path)

      unless create
        return {false, PluginResult.new(changed: false, failed: true, msg: "File #{path} does not exist. Use create: yes to create it.")}
      end

      unless check_mode
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(path, "")
      end

      {true, nil}
    end

    # Reads the file, runs the appropriate LineEditor operation, and writes
    # the result back (unless check_mode).
    private def apply(path : String, state : String, line : String?, regexp : String?, being_created : Bool, check_mode : Bool) : PluginResult
      original_content = File.exists?(path) ? File.read(path) : ""
      new_lines, changed = edit_lines(original_content, state, line, regexp)
      new_content = render_content(new_lines, original_content, being_created)

      backup_file = should_backup?(being_created, changed, path, check_mode) ? write_backup(path) : ""
      File.write(path, new_content) if changed && !check_mode

      diff = generate_unified_diff(original_content, new_content, path, path) if changed && @diff_mode

      # owner:/group:/mode: apply even when the line content itself was
      # already correct - real Ansible's lineinfile module runs the
      # generic file-attribute check unconditionally via
      # set_fs_attributes_if_different, so a mode-only drift (task's
      # mode: differs from the file's current mode, no line insertion
      # needed) still reports changed: true. Found via robertdebock's
      # grub role: `GRUB_TIMEOUT=5` already present in /etc/default/grub
      # on a fresh Rocky 9.6 image, but the task's own `mode: "0664"`
      # didn't match the file's actual 0644 - crystal previously never
      # even looked at the mode param once no line edit was needed.
      attrs_changed = apply_file_attrs(path, check_mode) if File.exists?(path)
      changed = changed || !!attrs_changed

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Line modified" : "Line already present",
        diff: diff,
        path: path,
        line: line || "",
        state: state,
        backup_file: backup_file
      )
    end

    private def edit_lines(original_content : String, state : String, line : String?, regexp : String?) : {Array(String), Bool}
      # String#split("\n") always adds one trailing "" artifact when the
      # content ends with "\n" (or is empty) - drop it to get the real
      # line list. This must NOT be conditioned on ends_with?("\n"): that
      # condition can only be true precisely when split already produced
      # the trailing "" that needs popping, so gating on its negation (as
      # a previous version of this code did) never actually pops anything.
      lines = original_content.split("\n")
      lines.pop if lines.size > 0 && lines.last.empty?

      if state == "absent"
        PluginHelpers::LineEditor.remove_matching(lines, line, regexp)
      else
        PluginHelpers::LineEditor.ensure_present(lines, line.not_nil!, regexp, is_true?(@params["backrefs"]?), @params["insertafter"]?, @params["insertbefore"]?)
      end
    end

    private def render_content(new_lines : Array(String), original_content : String, being_created : Bool) : String
      content = new_lines.join("\n")
      content += "\n" if original_content.ends_with?("\n") || (being_created && new_lines.size > 0)
      content
    end

    private def should_backup?(being_created : Bool, changed : Bool, path : String, check_mode : Bool) : Bool
      return false if being_created || check_mode || !changed
      is_true?(@params["backup"]?) && File.exists?(path)
    end

    # Checks owner:/group:/mode: against the file's current attributes
    # and applies any drift. Returns whether anything was actually
    # changed (skips the actual chown/chmod under check_mode, matching
    # every other check_mode-aware plugin in this codebase).
    private def apply_file_attrs(path : String, check_mode : Bool) : Bool
      changed = false
      info = begin
        File.info(path)
      rescue
        return false
      end

      if mode = @params["mode"]?
        if mode =~ /^0?\d+$/
          current = (info.permissions.value & 0o7777).to_s(8)
          target = mode.to_i(8).to_s(8)
          if current.lstrip('0').presence != target.lstrip('0').presence
            changed = true
            (File.chmod(path, mode.to_i(8)) rescue nil) unless check_mode
          end
        end
      end

      if owner = @params["owner"]?
        if user = System::User.find_by?(name: owner)
          if info.owner_id.to_s != user.id.to_s
            changed = true
            (File.chown(path, uid: user.id.to_i, gid: -1) rescue nil) unless check_mode
          end
        end
      end

      if group = @params["group"]?
        if grp = System::Group.find_by?(name: group)
          if info.group_id.to_s != grp.id.to_s
            changed = true
            (File.chown(path, uid: -1, gid: grp.id.to_i) rescue nil) unless check_mode
          end
        end
      end

      changed
    end

    private def write_backup(path : String) : String
      timestamp = Time.local.to_s("%Y%m%d-%H%M%S")
      backup_file = "#{path}.#{timestamp}.bak"
      File.copy(path, backup_file)
      backup_file
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::LineInFilePlugin.new(config)
plugin.run
