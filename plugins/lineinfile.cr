#!/usr/bin/env crystal

require "json"
require "file_utils"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/line_editor"

module CrystalPlay
  # Lineinfile plugin - manages a single line in a text file
  # Compatible with Ansible's ansible.builtin.lineinfile module
  #
  # Parameters:
  #   path (required): File to edit
  #   line: Line content (required for state: present, unless backrefs/regexp-only removal)
  #   regexp: Pattern used to find the line to replace/remove
  #   state: present (default) or absent
  #   create: Create the file if it doesn't exist (default: no)
  #   backup: Write a timestamped backup before changing the file (default: no)
  #   insertafter / insertbefore: EOF/BOF/END/BEGIN or a regexp
  #   backrefs: Substitute regexp match groups into `line` instead of replacing it wholesale
  class LineInFilePlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]?
      return missing_param("path") unless path

      line = @params["line"]?
      regexp = @params["regexp"]?
      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      if error = validate(state, line, regexp)
        return error
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
