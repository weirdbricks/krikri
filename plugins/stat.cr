#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/stat_fields"
require "../src/krikri/plugin_helpers/file_attributes"

module Krikri
  # Stat plugin - retrieves file/filesystem status.
  # Compatible with Ansible's ansible.builtin.stat module.
  #
  # - path: path to stat (required, aliases: dest, name - matches real
  #   Ansible's own argument_spec)
  # - follow: follow symlinks (default: false)
  # - get_checksum: compute a checksum of the file (default: true)
  # - checksum_algorithm: md5, sha1 (default), sha224, sha256, sha384,
  #   or sha512 (aliases: checksum, checksum_algo); anything else fails
  #   the task with real Ansible's own invalid-choice message
  # - get_mime: mimetype/charset via `file --mime-type --mime-encoding`
  #   (default: true, matching real Ansible; aliases: mime, mime_type,
  #   mime-type)
  # - get_attributes: lsattr flags via `lsattr -vd` (default: true,
  #   matching real Ansible; aliases: attr, attributes)
  #
  # get_mime/get_attributes both shell out - not a missed native-conversion
  # opportunity like stat's own core fields used to be, but the same thing
  # real Ansible's own module_utils/basic.py does: neither `file` nor
  # `lsattr` has a native Crystal (or Python stdlib) equivalent. Parsing
  # logic lives in `plugin_helpers/file_attributes.cr` (unit tested); this
  # plugin only runs the two commands via the existing local/remote
  # `remote_exec` split and swallows any failure into real Ansible's own
  # documented fallback values (mimetype/charset "unknown"; version nil,
  # attr_flags "", attributes []) rather than failing the task - matches a
  # filesystem that doesn't support lsattr (e.g. tmpfs) or a `file`/`lsattr`
  # binary that isn't installed, verified against a real ansible-playbook
  # run on exactly such a path.
  #
  # Native stat()/lstat() + hashlib-equivalent checksums (via
  # BasePlugin#native_stat/#native_checksum) rather than shelling to
  # `stat`/`md5sum`/`sha1sum`/`sha256sum`/`test -r`/`readlink` - matches
  # real Ansible's own stat module, which uses Python's os.stat() and
  # hashlib natively rather than shelling out too. Measured ~28x faster
  # per invocation than the previous shell-based implementation (5
  # subprocess spawns per call).
  #
  # This is always a read-only, never-`changed` module - like real
  # Ansible's stat, it exists to feed `register:` + `when:`, not to make
  # changes itself.
  class StatPlugin < BasePlugin
    # Real Ansible's alias resolution (_handle_aliases in module_utils/
    # common/parameters.py) iterates the argument_spec's aliases list in
    # order and each present alias OVERWRITES the canonical name, so any
    # present alias beats the canonical name, and among aliases the LAST
    # one in the spec's list wins. Live-verified against ansible-core
    # 2.19.4: `stat: {path: a.txt, name: b.txt}` stats b.txt (name is
    # path's last alias), and `checksum_algorithm: sha256, checksum:
    # md5` computes md5 (the alias wins even against the canonical).
    private def aliased_param(canonical : String, aliases : Array(String)) : String?
      value = @params[canonical]?
      aliases.each do |alias_name|
        value = @params[alias_name]? if @params.has_key?(alias_name)
      end
      value
    end

    def execute : PluginResult
      path = aliased_param("path", ["dest", "name"])
      unless path
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: path")
      end
      path = expand_tilde(path)

      follow = true?(@params["follow"]?, default: false)
      get_checksum = true?(@params["get_checksum"]?, default: true)
      get_mime = true?(aliased_param("get_mime", ["mime", "mime_type", "mime-type"]), default: true)
      get_attributes = true?(aliased_param("get_attributes", ["attr", "attributes"]), default: true)
      algorithm = aliased_param("checksum_algorithm", ["checksum", "checksum_algo"]) || "sha1"

      # Real Ansible's argument_spec validates checksum_algorithm against
      # its choices list at module setup and fails the task with exactly
      # this message (live-verified against ansible-core 2.19.4) -
      # previously an invalid algorithm silently fell through to SHA1
      # instead.
      stat_algorithms = ["md5", "sha1", "sha224", "sha256", "sha384", "sha512"]
      unless stat_algorithms.includes?(algorithm)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "value of checksum_algorithm must be one of: #{stat_algorithms.join(", ")}, got: #{algorithm}"
        )
      end

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
      add_mime(stat_hash, path) if get_mime
      add_attributes(stat_hash, path) if get_attributes

      PluginResult.new(changed: false, failed: false, msg: "", stat: stat_hash)
    end

    private def add_symlink_fields(stat_hash : Hash(String, JSON::Any), path : String) : Nil
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

    private def add_checksum(stat_hash : Hash(String, JSON::Any), path : String, algorithm : String) : Nil
      stat_hash["checksum"] = JSON::Any.new(native_checksum(path, algorithm))
    rescue
      # Matches the previous shell implementation's behavior: a checksum
      # failure (e.g. a permission-denied read) just omits the field
      # rather than failing the whole task.
    end

    private def add_mime(stat_hash : Hash(String, JSON::Any), path : String) : Nil
      result = remote_exec("file --mime-type --mime-encoding '#{path}'")
      mimetype, charset = result[:exit_code] == 0 ? PluginHelpers::FileAttributes.parse_mime(result[:stdout]) : {"unknown", "unknown"}
      stat_hash["mimetype"] = JSON::Any.new(mimetype)
      stat_hash["charset"] = JSON::Any.new(charset)
    end

    private def add_attributes(stat_hash : Hash(String, JSON::Any), path : String) : Nil
      result = remote_exec("lsattr -vd '#{path}'")
      version, attr_flags, attributes = result[:exit_code] == 0 ? PluginHelpers::FileAttributes.parse_lsattr(result[:stdout]) : {nil, "", [] of String}
      stat_hash["version"] = version ? JSON::Any.new(version) : JSON::Any.new(nil)
      stat_hash["attr_flags"] = JSON::Any.new(attr_flags)
      stat_hash["attributes"] = JSON::Any.new(attributes.map { |attribute| JSON::Any.new(attribute) })
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::StatPlugin.new(config)
plugin.run
