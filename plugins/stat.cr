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
  # Native stat()/lstat() + hashlib-equivalent checksums (via
  # BasePlugin#native_stat/#native_checksum) rather than shelling to
  # `stat`/`md5sum`/`sha1sum`/`sha256sum`/`test -r`/`readlink` - matches
  # real Ansible's own stat module, which uses Python's os.stat() and
  # hashlib natively rather than shelling out too. Measured ~28x faster
  # per invocation than the previous shell-based implementation (5
  # subprocess spawns per call) - see BENCHMARK_RESULTS.md.
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

      stat_hash = native_stat(path, follow)
      unless stat_hash
        return PluginResult.new(changed: false, failed: false, msg: "", stat: {"exists" => false})
      end

      stat_hash["readable"] = JSON::Any.new(File::Info.readable?(path))
      stat_hash["writeable"] = JSON::Any.new(File::Info.writable?(path))
      stat_hash["executable"] = JSON::Any.new(File::Info.executable?(path))

      is_link = stat_hash["islnk"].as_bool
      is_regular = stat_hash["isreg"].as_bool

      add_symlink_fields(stat_hash, path) if is_link
      add_checksum(stat_hash, path, algorithm) if get_checksum && is_regular

      PluginResult.new(changed: false, failed: false, msg: "", stat: stat_hash)
    end

    private def add_symlink_fields(stat_hash : Hash(String, JSON::Any), path : String)
      raw_target = File.readlink(path)
      resolved_target = begin
        File.realpath(path)
      rescue
        # A dangling symlink has no resolvable realpath - real Ansible's
        # os.path.realpath() doesn't raise for this either, it just
        # returns the unresolved path; match that instead of failing.
        raw_target
      end

      stat_hash["lnk_target"] = JSON::Any.new(raw_target)
      stat_hash["lnk_source"] = JSON::Any.new(resolved_target)
    end

    private def add_checksum(stat_hash : Hash(String, JSON::Any), path : String, algorithm : String)
      stat_hash["checksum"] = JSON::Any.new(native_checksum(path, algorithm))
    rescue
      # Matches the previous shell implementation's behavior: a checksum
      # failure (e.g. a permission-denied read) just omits the field
      # rather than failing the whole task.
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::StatPlugin.new(config)
plugin.run
