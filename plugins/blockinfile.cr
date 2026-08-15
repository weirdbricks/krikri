#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/block_editor"

module CrystalPlay
  # Blockinfile plugin - inserts/updates/removes a marker-delimited block of
  # text in a file. Compatible with Ansible's ansible.builtin.blockinfile.
  #
  # Parameters:
  #   path (required, aliases: dest, name - matches real Ansible's own
  #     argument_spec): File to edit
  #   block (alias content): Text to insert between the markers - a missing
  #     or empty block is treated as state: absent, matching real Ansible
  #   state: present (default) or absent
  #   marker: marker line template, {mark} replaced by marker_begin/marker_end
  #   marker_begin / marker_end: default "BEGIN" / "END"
  #   insertafter / insertbefore: EOF/BOF or a regexp (same as lineinfile)
  #   create: create the file if it doesn't exist (default: no)
  #   backup: write a timestamped backup before changing the file
  #   mode / owner / group: applied via BasePlugin#apply_owner_group_mode
  class BlockInFilePlugin < BasePlugin
    DEFAULT_MARKER = "# {mark} ANSIBLE MANAGED BLOCK"

    def execute : PluginResult
      path = @params["path"]? || @params["dest"]? || @params["name"]?
      return missing_param("path") unless path
      path = expand_tilde(path)

      check_mode = is_true?(@params["check_mode"]?)
      block = @params["block"]? || @params["content"]?
      state = block.nil? || block.empty? ? "absent" : (@params["state"]? || "present")

      being_created, error = ensure_file_exists(path, is_true?(@params["create"]?), check_mode)
      return error if error

      apply(path, state, block, being_created, check_mode)
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end

    private def ensure_file_exists(path : String, create : Bool, check_mode : Bool) : {Bool, PluginResult?}
      return {false, nil} if File.exists?(path)

      unless create
        return {false, PluginResult.new(changed: false, failed: true, msg: "Path #{path} does not exist!")}
      end

      unless check_mode
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(path, "")
      end

      {true, nil}
    end

    private def apply(path : String, state : String, block : String?, being_created : Bool, check_mode : Bool) : PluginResult
      original_content = File.exists?(path) ? File.read(path) : ""
      marker_begin_line, marker_end_line = marker_lines
      block_lines = block ? block.rstrip("\n").split("\n") : [] of String

      lines = split_lines(original_content)
      new_lines, changed = PluginHelpers::BlockEditor.apply(
        lines, marker_begin_line, marker_end_line, block_lines, state,
        @params["insertafter"]?, @params["insertbefore"]?
      )
      new_content = render_content(new_lines, original_content, being_created)

      backup_file = should_backup?(being_created, changed, path, check_mode) ? write_backup(path) : ""

      if changed && !check_mode
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(path, new_content)
        apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      end

      diff = generate_unified_diff(original_content, new_content, path, path) if changed && @diff_mode

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: result_msg(being_created, changed, state),
        diff: diff,
        path: path,
        backup_file: backup_file
      )
    end

    # A file that had to be created reports "File created" even when the
    # block write happens in the same call - matches real Ansible, verified
    # against a real `ansible-playbook` run rather than assumed.
    private def result_msg(being_created : Bool, changed : Bool, state : String) : String
      return "File created" if being_created && changed
      return "" unless changed
      state == "absent" ? "Block removed" : "Block inserted"
    end

    private def marker_lines : {String, String}
      marker = @params["marker"]? || DEFAULT_MARKER
      marker_begin = @params["marker_begin"]? || "BEGIN"
      marker_end = @params["marker_end"]? || "END"
      {marker.sub("{mark}", marker_begin), marker.sub("{mark}", marker_end)}
    end

    private def split_lines(content : String) : Array(String)
      lines = content.split("\n")
      lines.pop if lines.size > 0 && lines.last.empty?
      lines
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
plugin = CrystalPlay::BlockInFilePlugin.new(config)
plugin.run
