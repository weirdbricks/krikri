#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/stat_fields"

module CrystalPlay
  # Find plugin - recursively searches for files/directories matching
  # criteria. Compatible with Ansible's ansible.builtin.find module.
  #
  # Supported parameters:
  # - paths: comma-separated list of directories to search (required)
  # - patterns: comma-separated shell globs (or regexes with use_regex)
  #   matched against the basename (default: match everything)
  # - excludes: comma-separated shell globs matched against the basename,
  #   filtered out even if a pattern matched
  # - use_regex: treat patterns/excludes as regexes instead of shell globs
  #   (default: false)
  # - file_type: file (default) | directory | link | any
  # - recurse: descend into subdirectories (default: false)
  # - depth: max levels to descend when recurse: true (default: unlimited)
  # - hidden: include dotfiles/dotdirs (default: false) - a hidden
  #   directory is skipped entirely (not descended into), matching real
  #   Ansible's os.walk-based behavior
  # - size: minimum size in bytes (or negative for "at most"); accepts a
  #   b/k/m/g/t unit suffix
  # - get_checksum / checksum_algorithm: as in the stat plugin (default:
  #   get_checksum false, matching real Ansible's find default)
  #
  # Not implemented: age/age_stamp (time-based filtering), contains
  # (content regex search), read_whole_file, encoding, mode, limit - all
  # lower-value/rarer options than the core path+pattern+type search that
  # covers the overwhelming majority of real playbooks' `find:` usage.
  #
  # Directory walk via Dir.each_child + native lstat()/hashlib-equivalent
  # checksums (BasePlugin#native_stat/#native_checksum) rather than
  # shelling to `find`/`stat`/`md5sum`/`sha1sum`/`sha256sum`/`readlink`
  # once per matched entry - matches real Ansible's own find module,
  # which walks via Python's os.walk() and hashes via hashlib rather than
  # shelling out too. Measured ~150x faster over a 320-file tree with
  # checksums enabled than the previous shell-per-entry implementation -
  # see BENCHMARK_RESULTS.md.
  #
  # Read-only, never-`changed`, like stat.
  class FindPlugin < BasePlugin
    def execute : PluginResult
      paths_param = @params["paths"]?
      unless paths_param
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: paths")
      end

      paths = paths_param.split(",").map(&.strip).reject(&.empty?)
      patterns = (@params["patterns"]? || "").split(",").map(&.strip).reject(&.empty?)
      excludes = (@params["excludes"]? || "").split(",").map(&.strip).reject(&.empty?)
      use_regex = is_true?(@params["use_regex"]?, default: false)
      file_type = @params["file_type"]? || "file"
      recurse = is_true?(@params["recurse"]?, default: false)
      depth = @params["depth"]?.try(&.to_i?)
      hidden = is_true?(@params["hidden"]?, default: false)
      size_filter = @params["size"]?
      get_checksum = is_true?(@params["get_checksum"]?, default: false)
      algorithm = @params["checksum_algorithm"]? || "sha1"

      files = [] of JSON::Any
      examined = 0
      skipped_paths = {} of String => JSON::Any

      paths.each do |search_path|
        unless Dir.exists?(search_path)
          skipped_paths[search_path] = JSON::Any.new("'#{search_path}' is not a directory")
          next
        end

        entries = list_entries(search_path, recurse, depth)
        examined += entries.size

        entries.each do |entry_path|
          next if !hidden && hidden_path?(entry_path, search_path)

          basename = File.basename(entry_path)
          next unless matches_patterns?(basename, patterns, use_regex)
          next if !excludes.empty? && matches_patterns?(basename, excludes, use_regex)

          stat_hash = native_stat(entry_path, false)
          next unless stat_hash

          entry_is_link = stat_hash["islnk"].as_bool
          entry_is_regular = stat_hash["isreg"].as_bool
          next unless matches_file_type?(stat_hash, file_type)

          next unless matches_size?(stat_hash, size_filter)

          add_symlink_fields(stat_hash, entry_path) if entry_is_link
          add_checksum(stat_hash, entry_path, algorithm) if get_checksum && entry_is_regular

          files << JSON::Any.new(stat_hash)
        end
      end

      PluginResult.new(
        changed: false,
        failed: false,
        msg: "All paths examined",
        examined: examined,
        matched: files.size,
        files: files,
        skipped_paths: skipped_paths
      )
    end

    # Lists every path under search_path (not including search_path
    # itself) up to the given depth - direct children are depth 1,
    # matching real `find <path> -mindepth 1 -maxdepth N`'s own
    # numbering, which this replaces. Symlinked directories are never
    # descended into, matching `find`'s own default (-P, physical) walk -
    # verified this is also real Ansible's own os.walk()-based behavior.
    # Unreadable directories are skipped silently rather than failing the
    # whole search, matching the previous shell implementation's `2>/dev/null`.
    private def list_entries(search_path : String, recurse : Bool, depth : Int32?) : Array(String)
      max_depth = if !recurse
                    1
                  elsif depth
                    depth
                  else
                    Int32::MAX
                  end

      entries = [] of String
      walk(search_path, 1, max_depth, entries)
      entries
    end

    private def walk(dir : String, current_depth : Int32, max_depth : Int32, entries : Array(String))
      return if current_depth > max_depth

      Dir.each_child(dir) do |child|
        child_path = File.join(dir, child)
        entries << child_path

        if File.directory?(child_path) && !File.symlink?(child_path)
          walk(child_path, current_depth + 1, max_depth, entries)
        end
      end
    rescue
      # Permission denied, etc. - skip this directory, same as the
      # previous shell implementation's `2>/dev/null`.
    end

    # True if any path component between search_path and entry_path starts
    # with "." - real Ansible (os.walk-based) never descends into a hidden
    # directory, so anything under one is hidden too, not just direct
    # dotfiles.
    private def hidden_path?(entry_path : String, search_path : String) : Bool
      relative = entry_path.sub(/^#{Regex.escape(search_path)}\/?/, "")
      relative.split("/").any?(&.starts_with?("."))
    end

    private def matches_patterns?(basename : String, patterns : Array(String), use_regex : Bool) : Bool
      return true if patterns.empty?

      if use_regex
        patterns.any? { |pattern| basename.matches?(Regex.new(pattern)) }
      else
        patterns.any? { |pattern| File.match?(pattern, basename) }
      end
    end

    private def matches_file_type?(stat_hash : Hash(String, JSON::Any), wanted : String) : Bool
      case wanted
      when "file"      then stat_hash["isreg"].as_bool
      when "directory" then stat_hash["isdir"].as_bool
      when "link"      then stat_hash["islnk"].as_bool
      when "any"       then true
      else                  false
      end
    end

    private def matches_size?(stat_hash : Hash(String, JSON::Any), size_filter : String?) : Bool
      return true unless size_filter
      return true if stat_hash["isdir"]?.try(&.as_bool)

      threshold = parse_size(size_filter)
      return true unless threshold

      actual = stat_hash["size"].as_i64
      threshold < 0 ? actual <= threshold.abs : actual >= threshold
    end

    # Parses Ansible's size syntax: optional leading '-' (meaning "at most"
    # instead of "at least"), digits, optional b/k/m/g/t unit suffix.
    private def parse_size(spec : String) : Int64?
      match = spec.match(/^(-?\d+)([bkmgt]?)$/i)
      return nil unless match

      value = match[1].to_i64
      multiplier = case match[2].downcase
                   when "k" then 1024_i64
                   when "m" then 1024_i64 ** 2
                   when "g" then 1024_i64 ** 3
                   when "t" then 1024_i64 ** 4
                   else          1_i64
                   end
      value * multiplier
    end

    private def add_symlink_fields(stat_hash : Hash(String, JSON::Any), path : String)
      raw_target = File.readlink(path)
      resolved_target = begin
        File.realpath(path)
      rescue
        raw_target
      end

      stat_hash["lnk_target"] = JSON::Any.new(raw_target)
      stat_hash["lnk_source"] = JSON::Any.new(resolved_target)
    end

    private def add_checksum(stat_hash : Hash(String, JSON::Any), path : String, algorithm : String)
      stat_hash["checksum"] = JSON::Any.new(native_checksum(path, algorithm))
    rescue
      # A checksum failure (e.g. permission denied) just omits the field
      # rather than dropping the whole match.
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::FindPlugin.new(config)
plugin.run
