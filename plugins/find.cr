#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/stat_fields"
require "../src/crystal_play/plugin_helpers/find_mode_filter"

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
  # - age: minimum age (or negative for "at most"), same sign convention
  #   as size; accepts an s/m/h/d/w unit suffix (default seconds)
  # - age_stamp: which timestamp age compares against - atime/ctime/mtime
  #   (default mtime)
  # - contains: a regex matched against a regular file's content -
  #   line-by-line, anchored at the start of each line (default), or
  #   anywhere in the whole file when read_whole_file: true. Only applies
  #   when file_type: file (real Ansible's own restriction, not a scope
  #   cut here - verified against its actual source)
  # - read_whole_file: search the whole file for contains: instead of
  #   matching line-by-line (default: false)
  # - get_checksum / checksum_algorithm: as in the stat plugin (default:
  #   get_checksum false, matching real Ansible's find default)
  #
  # - mode / exact_mode: filters matched files by permission bits -
  #   octal ("0644") or the `u=rw,g=r,o=r` symbolic assignment form -
  #   see `PluginHelpers::FindModeFilter`'s own doc comment for exact
  #   semantics (verified against real ansible/modules/find.py's own
  #   `mode_filter` source, including its non-obvious non-exact "ANY
  #   requested bit present" semantics) and its documented scope cut
  #   (only `=` assignment, not the fuller chmod(1) `+`/`-`/`X`/`s`/`t`
  #   grammar).
  # - limit: stops once this many matches are found - this plugin's own
  #   directory walk is already a top-down, pre-order traversal (a
  #   parent directory's own direct matches are always found before
  #   descending into any of its subdirectories), matching real
  #   Ansible's own `os.walk()`-based "shallowest directory first"
  #   ordering, so no walk-order change was needed to support this.
  #
  # Not implemented: encoding (used only for a `contains:` search's own
  # file-reading encoding) - lower-value than the other two, and every
  # real caller found so far reads plain UTF-8/ASCII text anyway.
  #
  # Directory walk via Dir.each_child + native lstat()/hashlib-equivalent
  # checksums (BasePlugin#native_stat/#native_checksum) rather than
  # shelling to `find`/`stat`/`md5sum`/`sha1sum`/`sha256sum`/`readlink`
  # once per matched entry - matches real Ansible's own find module,
  # which walks via Python's os.walk() and hashes via hashlib rather than
  # shelling out too. Measured ~150x faster over a 320-file tree with
  # checksums enabled than the previous shell-per-entry implementation.
  #
  # Read-only, never-`changed`, like stat.
  class FindPlugin < BasePlugin
    # Bundles every filter/output option parsed from @params once, rather
    # than threading a dozen separate arguments through execute/match -
    # what pushed execute's own cyclomatic complexity over ameba's
    # threshold once age/contains joined the existing pattern/size/type
    # filters.
    private record Options,
      patterns : Array(String),
      excludes : Array(String),
      use_regex : Bool,
      file_type : String,
      recurse : Bool,
      depth : Int32?,
      hidden : Bool,
      size_filter : String?,
      age_filter : String?,
      age_stamp : String,
      contains : String?,
      read_whole_file : Bool,
      get_checksum : Bool,
      algorithm : String,
      now : Int64,
      mode : String?,
      exact_mode : Bool,
      limit : Int32?

    def execute : PluginResult
      # Real Ansible's find module declares `paths` with aliases `path`
      # and `name` (`ansible.plugins.modules.find`'s own argument_spec) -
      # a single-path invocation almost always uses the singular form
      # (`path: /var/spool/mail`, robertdebock.dovecot's own "Find users
      # in /var/spool/mail" task), which real Ansible accepts
      # transparently. This plugin only ever recognized the plural
      # `paths:`, failing outright ("missing required argument: paths")
      # on the far more common singular spelling.
      paths_param = @params["paths"]? || @params["path"]? || @params["name"]?
      unless paths_param
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: paths")
      end

      paths = parse_list_param(paths_param)
      options = Options.new(
        patterns: parse_list_param(@params["patterns"]? || ""),
        excludes: parse_list_param(@params["excludes"]? || ""),
        use_regex: is_true?(@params["use_regex"]?, default: false),
        file_type: @params["file_type"]? || "file",
        recurse: is_true?(@params["recurse"]?, default: false),
        depth: @params["depth"]?.try(&.to_i?),
        hidden: is_true?(@params["hidden"]?, default: false),
        size_filter: @params["size"]?,
        age_filter: @params["age"]?,
        age_stamp: @params["age_stamp"]? || "mtime",
        contains: @params["contains"]?,
        read_whole_file: is_true?(@params["read_whole_file"]?, default: false),
        get_checksum: is_true?(@params["get_checksum"]?, default: false),
        algorithm: @params["checksum_algorithm"]? || "sha1",
        now: Time.utc.to_unix,
        mode: @params["mode"]?,
        exact_mode: is_true?(@params["exact_mode"]?, default: true),
        limit: @params["limit"]?.try(&.to_i?),
      )

      files = [] of JSON::Any
      examined = 0
      skipped_paths = {} of String => JSON::Any

      paths.each do |search_path|
        unless Dir.exists?(search_path)
          skipped_paths[search_path] = JSON::Any.new("'#{search_path}' is not a directory")
          next
        end

        entries = list_entries(search_path, options.recurse, options.depth)

        entries.each do |entry_path|
          examined += 1
          next if !options.hidden && hidden_path?(entry_path, search_path)

          if stat_hash = match(entry_path, options)
            files << JSON::Any.new(stat_hash)
          end

          break if (limit = options.limit) && files.size >= limit
        end

        break if (limit = options.limit) && files.size >= limit
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

    # `paths:`/`patterns:`/`excludes:` accept real Ansible's comma-
    # separated string idiom directly, but a `{{ some_list_var }}`
    # template resolving to a real array (robertdebock.unowned_files'
    # own `paths: "{{ unowned_files_directories }}"`) instead renders to
    # the array's own bracketed text form (`["/opt/unowned_test"]`) -
    # this codebase's plugin params are always plain strings, and
    # nothing re-parses that bracketed text back into real elements
    # before this plugin's own naive `.split(",")` saw it, so a
    # single-element list became ONE path literally containing the
    # brackets and quotes, "not a directory". Same bug class documented
    # repeatedly elsewhere (apt.cr/package.cr/dnf.cr's own
    # `parse_package_names`) - each plugin that accepts a list-shaped
    # param needs this same defensive re-parse; find.cr never got it.
    private def parse_list_param(raw : String) : Array(String)
      trimmed = raw.strip
      if trimmed.starts_with?('[') && trimmed.ends_with?(']')
        parsed = begin
          Array(String).from_json(trimmed)
        rescue
          nil
        end
        # A Python-repr list (single-quoted strings) isn't valid JSON -
        # same fallback as package.cr's own parse_package_names.
        parsed ||= begin
          Array(String).from_json(trimmed.gsub('\'', '"'))
        rescue
          nil
        end
        return parsed.map(&.strip).reject(&.empty?) if parsed
      end

      trimmed.split(",").map(&.strip).reject(&.empty?)
    end

    # Returns the stat hash for entry_path if it passes every filter, nil
    # otherwise.
    private def match(entry_path : String, options : Options) : Hash(String, JSON::Any)?
      basename = File.basename(entry_path)
      return nil unless matches_patterns?(basename, options.patterns, options.use_regex)
      return nil if !options.excludes.empty? && matches_patterns?(basename, options.excludes, options.use_regex)

      stat_hash = native_stat(entry_path, false)
      return nil unless stat_hash
      return nil unless matches_file_type?(stat_hash, options.file_type)
      return nil unless matches_size?(stat_hash, options.size_filter)
      return nil unless matches_age?(stat_hash, options.age_filter, options.age_stamp, options.now)
      return nil if options.file_type == "file" && !matches_contains?(entry_path, options.contains, options.read_whole_file)
      return nil if options.mode && !PluginHelpers::FindModeFilter.matches?(stat_hash["mode"].as_s.to_i(8), options.mode.not_nil!, options.exact_mode)

      add_symlink_fields(stat_hash, entry_path) if stat_hash["islnk"].as_bool
      add_checksum(stat_hash, entry_path, options.algorithm) if options.get_checksum && stat_hash["isreg"].as_bool

      stat_hash
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

    # Same sign convention as size: positive age means "at least this old"
    # (now - timestamp >= age), negative means "at most this old"
    # (now - timestamp <= abs(age)) - verified against real Ansible's own
    # find.py agefilter() source, not guessed from the docs' prose.
    private def matches_age?(stat_hash : Hash(String, JSON::Any), age_filter : String?, age_stamp : String, now : Int64) : Bool
      return true unless age_filter

      age = parse_age(age_filter)
      return true unless age

      timestamp = stat_hash[age_stamp]?.try(&.as_i64) || stat_hash["mtime"].as_i64
      elapsed = now - timestamp
      age >= 0 ? elapsed >= age.abs : elapsed <= age.abs
    end

    # Parses Ansible's age syntax: optional leading '-' (meaning "at most"
    # instead of "at least"), digits, optional s/m/h/d/w unit suffix
    # (default seconds) - verified against find.py's own
    # `^(-?\d+)(s|m|h|d|w)?$` regex and seconds_per_unit table.
    private def parse_age(spec : String) : Int64?
      match = spec.downcase.match(/^(-?\d+)(s|m|h|d|w)?$/)
      return nil unless match

      value = match[1].to_i64
      multiplier = case match[2]?
                   when "m" then 60_i64
                   when "h" then 3600_i64
                   when "d" then 86400_i64
                   when "w" then 604800_i64
                   else          1_i64
                   end
      value * multiplier
    end

    # contains: only applies to regular files (real Ansible's own
    # restriction: "Works only when file_type is file" - the caller
    # already gates this on file_type == "file"). read_whole_file: false
    # (the default) matches line-by-line, anchored at the start of each
    # line - Python's re.match() semantics, which \A (not multiline ^)
    # replicates in Crystal's PCRE-based Regex; read_whole_file: true
    # searches anywhere in the whole file content (Python's re.search()).
    # A read failure (permission denied, binary/invalid encoding, etc.)
    # is treated as no match, same as real Ansible's own broad `except
    # Exception: pass` around this.
    private def matches_contains?(path : String, contains : String?, read_whole_file : Bool) : Bool
      return true unless contains

      pattern = Regex.new(contains)
      content = File.read(path)

      if read_whole_file
        !!(content =~ pattern)
      else
        anchored = Regex.new("\\A(?:#{contains})")
        content.each_line.any?(&.matches?(anchored))
      end
    rescue
      false
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
