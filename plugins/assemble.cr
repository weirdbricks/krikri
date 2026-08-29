#!/usr/bin/env crystal

# assemble module (ansible.builtin.assemble) - concatenates fragment files
# from a `src` directory into one `dest` file, alphabetically by filename.
# `remote_src` defaults to true (unlike copy:/template:/unarchive:) - most
# real-world uses assemble fragments that were already templated/copied
# onto the target in an earlier task (e.g. a sudoers.d/ or sshd_config.d/
# style drop-in directory), reading `src` directly on whatever filesystem
# this process is actually running on (the remote target for a real SSH
# host, same as every other plugin - see native_stat's own comment on why
# plain File/Dir calls are always correct here). `remote_src: false`
# instead has TaskExecutor#stage_assemble_dir SCP the whole src directory
# tree up first, same pattern as copy:'s stage_directory_copy_source.
#
# Parameters:
#   src (required): directory containing fragment files
#   dest (required): file to assemble them into
#   delimiter (optional): inserted between fragments
#   regexp (optional): only fragments whose filename matches this regex
#   ignore_hidden (optional bool, default false): skip dotfiles
#   backup (optional bool, default false)
#   owner/group/mode (optional): applied to dest

require "json"
require "digest/md5"
require "file_utils"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class AssemblePlugin < BasePlugin
    def execute : PluginResult
      src = @params["src"]?
      dest = @params["dest"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: src") unless src
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: dest") unless dest

      unless Dir.exists?(src)
        return PluginResult.new(changed: false, failed: true, msg: "Source (#{src}) does not exist")
      end

      ignore_hidden = true?(@params["ignore_hidden"]?)
      regexp = @params["regexp"]?.try { |r| Regex.new(r) rescue nil }
      delimiter = @params["delimiter"]?

      fragments = Dir.children(src).sort.select do |name|
        next false if ignore_hidden && name.starts_with?('.')
        full = File.join(src, name)
        next false unless File.file?(full)
        regexp.nil? || regexp.not_nil!.matches?(name)
      end

      assembled = fragments.map { |name| File.read(File.join(src, name)) }
      content = delimiter ? assembled.join(delimiter.includes?("\n") ? delimiter : "#{delimiter}\n") : assembled.join

      existing = File.exists?(dest) ? File.read(dest) : nil
      changed = existing != content
      check_mode = true?(@params["check_mode"]?)
      diff_mode = true?(@params["diff_mode"]?)

      diff = diff_mode ? generate_unified_diff(existing || "", content, dest, dest) : nil
      backup_file = ""

      if changed && !check_mode
        if existing && true?(@params["backup"]?)
          backup_file = "#{dest}.#{Time.utc.to_unix}.bak"
          File.write(backup_file, existing)
        end

        dest_dir = File.dirname(dest)
        Dir.mkdir_p(dest_dir) unless Dir.exists?(dest_dir)
        File.write(dest, content)
        apply_owner_group_mode(dest, @params["owner"]?, @params["group"]?, @params["mode"]?)
      end

      # __cleanup_after_assemble - set by TaskExecutor#stage_assemble_dir
      # when remote_src: false SCP'd a whole controller-side directory up
      # to a scratch path first. Best-effort, mirrors copy.cr's own
      # __cleanup_after_copy_dir.
      if @params["__cleanup_after_assemble"]? == "true"
        FileUtils.rm_rf(src) rescue nil
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "" : "dest already matches assembled content",
        diff: diff,
        dest: dest,
        checksum: Digest::MD5.hexdigest(content),
        backup_file: backup_file
      )
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::AssemblePlugin.new(config)
plugin.run
