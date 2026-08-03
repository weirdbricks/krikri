#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/archive_paths"

module CrystalPlay
  # Archive plugin - compresses/archives files and directories.
  # Compatible with Ansible's archive module - registered here as
  # community.general.archive, matching its real FQCN (it lives in the
  # separate community.general collection, not ansible-core itself -
  # verified via `ansible-doc archive`, not assumed as ansible.builtin.*
  # like most other plugins in this codebase).
  #
  # Supported parameters:
  # - path: comma-separated list of paths/shell-globs to archive (required)
  # - dest: destination archive file path (required)
  # - format: bz2 | gz (default) | tar | xz | zip
  # - force_archive: always build a real archive, even for a single file
  #   with format gz/bz2/xz (default: false - a single file with a
  #   compression-only format is gzip/bzip2/xz-compressed directly, not
  #   wrapped in a tar; format tar/zip always produce a real archive
  #   regardless of this flag, matching real Ansible's own behavior)
  # - remove: delete the source path(s) after a successful archive
  #   (default: false)
  # - exclusion_patterns: comma-separated shell-glob patterns matched
  #   against each member's path relative to the archive root, excluded
  #   from the result
  # - mode / owner / group: applied to the resulting dest file
  #
  # Not implemented: exclude_path - verified against a real
  # community.general 11.2.1 install that this documented option is
  # actually a no-op there (files it names still end up in the archive),
  # so implementing it "correctly" per the docs would make crystal-ansible
  # diverge from real Ansible's actual behavior, not match it;
  # exclusion_patterns (which does work) is supported instead. Also not
  # implemented: attributes/selevel/serole/setype/seuser (SELinux),
  # unsafe_writes.
  #
  # Idempotency is checksum-based like real Ansible, but computed via
  # shell tools (tar/zip listings + a content checksum) rather than
  # replicating Python's tarfile per-member header checksum exactly -
  # this compares crystal-ansible's own archives against themselves
  # across runs, which doesn't require bit-for-bit parity with Python's
  # internal algorithm to be correct.
  class ArchivePlugin < BasePlugin
    def execute : PluginResult
      path_param = @params["path"]?
      dest = @params["dest"]?
      unless path_param && dest
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path and dest are both required")
      end

      format = @params["format"]? || "gz"
      unless %w[bz2 gz tar xz zip].includes?(format)
        return PluginResult.new(changed: false, failed: true, msg: "format must be one of bz2, gz, tar, xz, zip")
      end

      run(path_param, dest, format)
    end

    private def run(path_param : String, dest : String, format : String) : PluginResult
      requested_paths = path_param.split(",").map(&.strip).reject(&.empty?)
      force_archive = is_true?(@params["force_archive"]?, default: false)
      remove = is_true?(@params["remove"]?, default: false)
      exclusion_patterns = (@params["exclusion_patterns"]? || "").split(",").map(&.strip).reject(&.empty?)

      expanded_paths, missing = expand_paths(requested_paths)
      found_paths = expanded_paths.reject { |path| missing.includes?(path) }

      if found_paths.empty?
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "",
          dest: dest,
          dest_state: "absent",
          archived: [] of String,
          missing: missing,
          expanded_paths: expanded_paths
        )
      end

      single_compress = !force_archive && format != "tar" && format != "zip" &&
                        expanded_paths.size == 1 && found_paths.size == 1 && !remote_dir_exists?(found_paths[0])

      root = PluginHelpers::ArchivePaths.common_path(expanded_paths)
      members = single_compress ? found_paths : collect_members(found_paths, root, exclusion_patterns)

      build_and_finalize(dest, format, single_compress, root, members, found_paths, missing, expanded_paths, remove)
    end

    # Expands each requested path: a shell-glob (contains * or ?) that
    # matches nothing silently contributes nothing (not "missing"); a
    # literal path that doesn't exist is kept in the expanded list but
    # also recorded as missing - matching real Ansible's expand_paths.
    private def expand_paths(requested : Array(String)) : {Array(String), Array(String)}
      expanded = [] of String
      missing = [] of String

      requested.each do |pattern|
        if pattern.includes?('*') || pattern.includes?('?')
          matches = remote_exec("for f in #{pattern}; do [ -e \"$f\" ] && printf '%s\\n' \"$f\"; done")[:stdout]
          expanded.concat(matches.split("\n").map(&.strip).reject(&.empty?))
        else
          expanded << pattern
          missing << pattern unless remote_exec("test -e #{pattern}")[:exit_code] == 0
        end
      end

      {expanded, missing}
    end

    # Walks each found path (recursively, if it's a directory) collecting
    # every member's absolute path. A requested directory's own entry is
    # NOT included, only its descendants - verified against
    # community.general's actual archive.py source (add_targets() calls
    # os.walk(target) and adds every directory_name/file_name found
    # inside, but never target itself; a requested FILE, which has no
    # descendants to walk, is added directly). This is the exact member
    # list used both for the JSON result's `archived` field and for
    # actually building the archive (see build_archive, which adds each
    # member individually with recursion disabled - passing a directory
    # member and its own already-listed children to tar/zip's own
    # recursion would double-include the children).
    private def collect_members(found_paths : Array(String), root : String, exclusion_patterns : Array(String)) : Array(String)
      members = [] of String

      found_paths.each do |path|
        if remote_dir_exists?(path)
          entries = remote_exec("find #{path} -mindepth 1 2>/dev/null")[:stdout].split("\n").map(&.strip).reject(&.empty?)
          members.concat(entries)
        else
          members << path
        end
      end

      return members if exclusion_patterns.empty?

      # Matched against the basename, like tar's own --exclude behavior
      # for a slash-free pattern (verified: `tar --exclude="*skip*"`
      # excludes by path component, not by requiring "*" to cross "/").
      members.reject do |member|
        basename = File.basename(member)
        exclusion_patterns.any? { |pattern| File.match?(pattern, basename) }
      end
    end

    private def build_and_finalize(
      dest : String,
      format : String,
      single_compress : Bool,
      root : String,
      members : Array(String),
      found_paths : Array(String),
      missing : Array(String),
      expanded_paths : Array(String),
      remove : Bool,
    ) : PluginResult
      tmp_dest = "#{dest}.crystal-ansible-tmp-#{Random::Secure.hex(6)}"

      build_result = if single_compress
                       build_compress(found_paths[0], format, tmp_dest)
                     else
                       build_archive(root, members, format, tmp_dest)
                     end

      unless build_result
        remote_exec("rm -f #{tmp_dest}")
        return PluginResult.new(changed: false, failed: true, msg: "failed to build archive")
      end

      old_signature = remote_file_exists?(dest) ? signature(dest, format, single_compress) : nil
      new_signature = signature(tmp_dest, format, single_compress)
      changed = old_signature != new_signature

      if changed
        remote_exec("mv #{tmp_dest} #{dest}")
      else
        remote_exec("rm -f #{tmp_dest}")
      end

      remove_sources(found_paths) if remove

      dest_state = missing.empty? ? (single_compress ? "compress" : "archive") : "incomplete"
      apply_dest_attributes(dest)

      archived = single_compress ? found_paths : members
      stat_fields = dest_stat_fields(dest)

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: "",
        dest: dest,
        dest_state: dest_state,
        archived: archived,
        missing: missing,
        expanded_paths: expanded_paths,
        arcroot: root,
        size: stat_fields[:size],
        uid: stat_fields[:uid],
        gid: stat_fields[:gid],
        owner: stat_fields[:owner],
        group: stat_fields[:group],
        mode: stat_fields[:mode],
        state: stat_fields[:state]
      )
    end

    private def build_compress(source : String, format : String, tmp_dest : String) : Bool
      cmd = case format
            when "bz2" then "bzip2 -c #{source} > #{tmp_dest}"
            when "xz"  then "xz -c #{source} > #{tmp_dest}"
            else            "gzip -c #{source} > #{tmp_dest}"
            end
      remote_exec(cmd)[:exit_code] == 0
    end

    # Adds every already-walked, already-exclusion-filtered `members` entry
    # individually, with each tool's own recursion disabled
    # (`--no-recursion` for tar; zip needs no `-r` at all since every
    # member - files and subdirectories alike - is already listed
    # explicitly). Passing a directory member to a recursing tar/zip
    # while ALSO passing its own children as separate arguments would
    # double-include the children - verified by diffing actual tar
    # contents against what was requested, not assumed to be correct.
    private def build_archive(root : String, members : Array(String), format : String, tmp_dest : String) : Bool
      relative_members = members.map { |member| member.starts_with?(root) ? member[root.size..-1] : member }
      return false if relative_members.empty?

      quoted_members = relative_members.map { |member| "\"#{member}\"" }.join(" ")

      cmd = if format == "zip"
              "cd #{root} && zip -q #{tmp_dest} #{quoted_members}"
            else
              tar_flag = case format
                         when "bz2" then "j"
                         when "xz"  then "J"
                         when "tar" then ""
                         else            "z"
                         end
              "cd #{root} && tar --no-recursion -c#{tar_flag}f #{tmp_dest} #{quoted_members}"
            end

      remote_exec(cmd)[:exit_code] == 0
    end

    # A content+membership signature for `path`, used to decide whether a
    # freshly-built archive differs from what's already at dest. Not the
    # same algorithm real Ansible's Python implementation uses internally
    # (tarfile per-member header checksums) - this compares
    # crystal-ansible's own archives against themselves across runs.
    private def signature(path : String, format : String, single_compress : Bool) : String?
      return nil unless remote_file_exists?(path)

      if single_compress
        decompress_cmd = case format
                         when "bz2" then "bzip2 -dc"
                         when "xz"  then "xz -dc"
                         else            "gzip -dc"
                         end
        result = remote_exec("#{decompress_cmd} #{path} 2>/dev/null | md5sum")
        return nil unless result[:exit_code] == 0
        result[:stdout].strip
      elsif format == "zip"
        names = remote_exec("zipinfo -1 #{path} 2>/dev/null | sort")[:stdout].strip
        content = remote_exec("unzip -p #{path} 2>/dev/null | md5sum")[:stdout].strip
        "#{names}|#{content}"
      else
        names = remote_exec("tar tf #{path} 2>/dev/null | sort")[:stdout].strip
        content = remote_exec("tar xf #{path} -O 2>/dev/null | md5sum")[:stdout].strip
        "#{names}|#{content}"
      end
    end

    private def remove_sources(found_paths : Array(String))
      found_paths.each { |path| remote_exec("rm -rf #{path}") }
    end

    private def apply_dest_attributes(dest : String)
      if owner = @params["owner"]?
        remote_exec("chown #{owner} #{dest}")
      end
      if group = @params["group"]?
        remote_exec("chgrp #{group} #{dest}")
      end
      if mode = @params["mode"]?
        remote_exec("chmod #{mode} #{dest}")
      end
    end

    private def dest_stat_fields(dest : String) : NamedTuple(size: Int64, uid: Int64, gid: Int64, owner: String, group: String, mode: String, state: String)
      result = remote_exec("stat -c '%s|%u|%g|%U|%G|%a' #{dest} 2>/dev/null")
      fields = result[:stdout].strip.split("|")

      if result[:exit_code] == 0 && fields.size == 6
        {
          size:  fields[0].to_i64,
          uid:   fields[1].to_i64,
          gid:   fields[2].to_i64,
          owner: fields[3],
          group: fields[4],
          mode:  "0#{fields[5]}",
          state: "file",
        }
      else
        {size: 0_i64, uid: 0_i64, gid: 0_i64, owner: "", group: "", mode: "", state: "absent"}
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::ArchivePlugin.new(config)
plugin.run
