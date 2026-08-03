#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/stat_fields"

module CrystalPlay
  # Stat plugin - retrieves file/filesystem status.
  # Compatible with Ansible's ansible.builtin.stat module.
  #
  # Supported parameters:
  # - path: path to stat (required)
  # - follow: follow symlinks (default: false)
  # - get_checksum: compute a checksum of the file (default: true)
  # - checksum_algorithm: md5, sha1 (default), or sha256
  #
  # Not implemented: get_attributes (lsattr flags), get_mime
  # (mimetype/charset via `file`) - both default true in real Ansible but
  # are lower-value, tool-dependent extras; omitted from the returned
  # `stat` dict entirely rather than faked.
  #
  # This is always a read-only, never-`changed` module - like real
  # Ansible's stat, it exists to feed `register:` + `when:`, not to make
  # changes itself.
  class StatPlugin < BasePlugin
    def execute : PluginResult
      path = @params["path"]?
      unless path
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path")
      end

      follow = is_true?(@params["follow"]?, default: false)
      get_checksum = is_true?(@params["get_checksum"]?, default: true)
      algorithm = @params["checksum_algorithm"]? || "sha1"

      stat_flag = follow ? "-L" : ""
      result = remote_exec("stat #{stat_flag} -c '%a|%s|%Y|%X|%Z|%i|%d|%h|%u|%g|%U|%G|%F' #{path} 2>/dev/null")

      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: false, msg: "", stat: {"exists" => false})
      end

      stat_hash = PluginHelpers::StatFields.parse(path, result[:stdout])
      file_type = PluginHelpers::StatFields.file_type(result[:stdout])
      unless stat_hash && file_type
        return PluginResult.new(changed: false, failed: true, msg: "stat: unexpected output format")
      end
      stat_hash["readable"] = JSON::Any.new(remote_exec("test -r #{path}")[:exit_code] == 0)
      stat_hash["writeable"] = JSON::Any.new(remote_exec("test -w #{path}")[:exit_code] == 0)
      stat_hash["executable"] = JSON::Any.new(remote_exec("test -x #{path}")[:exit_code] == 0)
      add_symlink_fields(stat_hash, path, file_type)
      add_checksum(stat_hash, path, file_type, algorithm) if get_checksum

      PluginResult.new(changed: false, failed: false, msg: "", stat: stat_hash)
    end

    private def add_symlink_fields(stat_hash : Hash(String, JSON::Any), path : String, file_type : String)
      return unless PluginHelpers::StatFields.symlink?(file_type)

      raw_target = remote_exec("readlink #{path}")[:stdout].strip
      resolved_target = remote_exec("readlink -f #{path}")[:stdout].strip
      stat_hash["lnk_target"] = JSON.parse(raw_target.to_json)
      stat_hash["lnk_source"] = JSON.parse(resolved_target.to_json)
    end

    private def add_checksum(stat_hash : Hash(String, JSON::Any), path : String, file_type : String, algorithm : String)
      return unless PluginHelpers::StatFields.regular_file?(file_type)

      checksum_cmd = case algorithm
                     when "md5"    then "md5sum"
                     when "sha256" then "sha256sum"
                     else               "sha1sum"
                     end
      checksum_result = remote_exec("#{checksum_cmd} #{path} 2>/dev/null")
      return unless checksum_result[:exit_code] == 0

      checksum = checksum_result[:stdout].strip.split(" ").first?
      stat_hash["checksum"] = JSON.parse(checksum.to_json) if checksum
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::StatPlugin.new(config)
plugin.run
