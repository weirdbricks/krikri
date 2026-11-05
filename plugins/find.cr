#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/stat_fields"
require "../src/krikri/plugin_helpers/find_mode_filter"

module Krikri
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
  #   directory is skipped entirely (not descended into), matching
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
  #   when file_type: file (Ansible's own restriction, not a scope
  #   cut here - verified against its actual source)
  # - read_whole_file: search the whole file for contains: instead of
  #   matching line-by-line (default: false)
  # - get_checksum / checksum_algorithm: as in the stat plugin (default:
  #   get_checksum false, matching Ansible's find default)
  #
  # - mode / exact_mode: filters matched files by permission bits -
  #   octal ("0644") or the `u=rw,g=r,o=r` symbolic assignment form -
  #   see `PluginHelpers::FindModeFilter`'s own doc comment for exact
  #   semantics (verified against the Ansible module's own
  #   `mode_filter` source, including its non-obvious non-exact "ANY
  #   requested bit present" semantics) and its documented scope cut
  #   (only `=` assignment, not the fuller chmod(1) `+`/`-`/`X`/`s`/`t`
  #   grammar).
  # - limit: stops once this many matches are found - this plugin's own
  #   directory walk is already a top-down, pre-order traversal (a
  #   parent directory's own direct matches are always found before
  #   descending into any of its subdirectories), matching
  #   Ansible's own `os.walk()`-based "shallowest directory first"
  #   ordering, so no walk-order change was needed to support this.
  #
  # - follow: descend into symlinked directories when recursing (default:
  #   false). Classification still uses lstat() regardless of follow (Ansible's own os.lstat() in its main loop), so a symlink-to-file
  #   still only matches file_type: link/any even with follow: true -
  #   follow only changes which directories are walked into (os.walk's
  #   own followlinks flag).
  # - encoding: the text encoding used when `contains:` reads a file's
  #   content for matching (e.g. latin-1; Ansible 2.17+'s
  #   contentfilter opens the file with `open(..., encoding=encoding)`).
  #   When not given, content is decoded with Python's default codec
  #   (UTF-8) strictly: an undecodable byte abandons the whole search
  #   path with real's "Failed to read the file ..." encoding-error
  #   skip - it does not fall back to byte-wise matching. Encoding does
  #   NOT affect get_checksum - Ansible's digest_from_file hashes raw
  #   bytes regardless of encoding.
  #
  # Directory walk via Dir.each_child + native lstat()/hashlib-equivalent
  # checksums (BasePlugin#native_stat/#native_checksum) rather than
  # shelling to `find`/`stat`/`md5sum`/`sha1sum`/`sha256sum`/`readlink`
  # once per matched entry - matches Ansible's own find module,
  # which walks via Python's os.walk() and hashes via hashlib rather than
  # shelling out too. Measured ~150x faster over a 320-file tree with
  # checksums enabled than the previous shell-per-entry implementation.
  #
  # Read-only, never-`changed`, like stat.
  class FindPlugin < BasePlugin
    # Ansible's registered find result order (live-verified vs 2.19.11).
    private FIND_KEY_ORDER = %w[files changed msg matched examined skipped_paths]

    # A walked entry's upfront lstat outcome: the stat hash on success,
    # the failing errno otherwise. Real find lstats every entry before
    # filtering and turns a failure into a skipped entry (see match).
    private alias EntryStat = Hash(String, JSON::Any)? | Errno

    # A contains: read failure real find turns into a per-search-path
    # skip, not a per-file miss: an unknown encoding: name (open()'s
    # LookupError, "unknown encoding: X") or an undecodable file under
    # the strict default/UTF-8 decode ("Failed to read the file <path>
    # due to an encoding error. current encoding: ...").
    # collect_matches records the exception's str() verbatim in
    # skipped_paths and warns about the TOP search path.
    class UnknownEncoding < Exception; end

    # A directory-listing error Ansible's handle_walk_errors does NOT swallow
    # (anything but EPERM/EACCES/ENOENT): real re-raises it out of
    # os.walk into the per-search-path handler, which records the TOP
    # search path (not the failing subdirectory) and warns about it.
    class WalkError < Exception; end

    # ansible.builtin.find's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.find). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[exact_mode follow get_checksum hidden read_whole_file recurse use_regex]
    end

    # Bundles every filter/output option parsed from @params once, rather
    # than threading a dozen separate arguments through execute/mch -
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
      limit : Int32?,
      follow : Bool,
      encoding : String?

    def execute : PluginResult
      validate_bool_params!
      # Ansible's find module declares `paths` with aliases `path`
      # and `name` (`ansible.plugins.modules.find`'s own argument_spec) -
      # a single-path invocation almost always uses the singular form
      # (`path: /var/spool/mail`, robertdebock.dovecot's own "Find users
      # in /var/spool/mail" task), which Ansible accepts
      # transparently. This plugin only ever recognized the plural
      # `paths:`, failing outright ("missing required argument: paths")
      # on the far more common singular spelling.
      paths_param = @params["paths"]? || @params["path"]? || @params["name"]?
      unless paths_param
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: paths")
      end

      paths = parse_list_param(paths_param)
      # Same argument_spec alias family as paths' `path`/`name` above:
      # Ansible's find declares the singular `pattern` for `patterns`
      # and `exclude` for `excludes` - a hardcoded single-pattern task
      # (`pattern: ".authorized_keys"`, robertdebock.forensics) was
      # silently ignored here, matching every file in the walk instead
      # of just the named one.
      options = Options.new(
        patterns: parse_list_param(@params["patterns"]? || @params["pattern"]? || ""),
        excludes: parse_list_param(@params["excludes"]? || @params["exclude"]? || ""),
        use_regex: true?(@params["use_regex"]?, default: false),
        file_type: @params["file_type"]? || "file",
        recurse: true?(@params["recurse"]?, default: false),
        depth: @params["depth"]?.try(&.to_i?),
        hidden: true?(@params["hidden"]?, default: false),
        size_filter: @params["size"]?,
        age_filter: @params["age"]?,
        age_stamp: @params["age_stamp"]? || "mtime",
        contains: @params["contains"]?,
        read_whole_file: true?(@params["read_whole_file"]?, default: false),
        get_checksum: true?(@params["get_checksum"]?, default: false),
        algorithm: @params["checksum_algorithm"]? || "sha1",
        now: Time.utc.to_unix,
        mode: @params["mode"]?,
        exact_mode: true?(@params["exact_mode"]?, default: true),
        limit: @params["limit"]?.try(&.to_i?),
        follow: true?(@params["follow"]?, default: false),
        encoding: @params["encoding"]?,
      )

      # Ansible's find fails the whole module when `age:` or `size:`
      # doesn't parse ("banana" etc.); it does NOT silently drop the
      # filter and return unfiltered matches.
      if (age = options.age_filter) && parse_age(age).nil?
        return PluginResult.new(changed: false, failed: true, msg: "failed to process age", age: age)
      end
      if (size = options.size_filter) && parse_size(size).nil?
        return PluginResult.new(changed: false, failed: true, msg: "failed to process size", size: size)
      end

      files, examined, skipped_paths, warnings = collect_matches(paths, options)

      # Real find.py warns ONLY for the per-search-path failures (a
      # not-a-directory path, an UnknownEncoding hit, a non-EPERM/EACCES/
      # ENOENT directory-listing error), for every ENTRY whose upfront
      # lstat failed (see match's own comment), and - live-verified vs
      # 2.19.11 - any warning flips the result msg to "Not all paths
      # examined, check warnings for details". An unreadable directory
      # recorded by os.walk's onerror handler stays silent: msg unchanged,
      # no warnings key (see walk's rescue).
      extra = warnings.empty? ? nil : warnings
      msg = extra ? "Not all paths examined, check warnings for details" : "All paths examined"

      if extra
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: msg,
          examined: examined,
          matched: files.size,
          files: files,
          skipped_paths: skipped_paths,
          warnings: extra,
          key_order: FIND_KEY_ORDER
        )
      end

      # Ansible's registered find result runs files, changed, msg, matched,
      # examined, skipped_paths, failed (live-verified vs 2.19.11 via
      # `{{ r | to_json }}`; check mode is the same shape). warnings is
      # unlisted - it trails (its real position was not confirmed live).
      PluginResult.new(
        changed: false,
        failed: false,
        msg: msg,
        examined: examined,
        matched: files.size,
        files: files,
        skipped_paths: skipped_paths,
        key_order: FIND_KEY_ORDER
      )
    end

    private def collect_matches(paths : Array(String), options : Options) : {Array(JSON::Any), Int32, Hash(String, JSON::Any), Array(String)}
      files = [] of JSON::Any
      examined = 0
      skipped_paths = {} of String => JSON::Any
      warnings = [] of String

      paths.each do |search_path|
        unless Dir.exists?(search_path)
          why = "'#{search_path}' is not a directory"
          skipped_paths[search_path] = JSON::Any.new(why)
          warnings << "Skipped '#{search_path}' path due to this access issue: #{why}\n"
          next
        end

        begin
          # The entry loop lives HERE, not in a helper, so the examined
          # count survives a mid-path decode error: real counts every
          # filesystem object of the directories it yielded before the
          # failing one, and a helper-local counter would be unwound
          # with the exception.
          entries = list_entries(search_path, options, skipped_paths)
          entries.each do |entry_path, stat_or_errno|
            examined += 1
            next if !options.hidden && hidden_path?(entry_path, search_path)

            if stat_hash = match(entry_path, stat_or_errno, options, skipped_paths, warnings)
              files << JSON::Any.new(stat_hash)
            end

            break if (limit = options.limit) && files.size >= limit
          end
        rescue ex : UnknownEncoding
          skipped_paths[search_path] = JSON::Any.new(ex.message.to_s)
          warnings << "Skipped '#{search_path}' path due to this access issue: #{ex.message}\n"
          next
        rescue ex : WalkError
          skipped_paths[search_path] = JSON::Any.new(ex.message.to_s)
          warnings << "Skipped '#{search_path}' path due to this access issue: #{ex.message}\n"
          next
        end
        break if (limit = options.limit) && files.size >= limit
      end

      {files, examined, skipped_paths, warnings}
    end

    # `paths:`/`patterns:`/`excludes:` accept Ansible's comma-
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
        # ONLY valid JSON - never a Python-repr repair pass: a value that
        # merely LOOKS like a container is a plain STRING in
        # ansible-core (live-verified vs ansible-playbook 2.19.11, see
        # apt.cr's parse_package_names). A whole-value `{{ list_var }}`
        # container arg arrives as the double-quoted JSON the wire
        # serialized it to (see substitute_task_params's
        # whole-single-span comment), which the plain JSON parse above
        # already handles.
        return parsed.map(&.strip).reject(&.empty?) if parsed
      end

      trimmed.split(",").map(&.strip).reject(&.empty?)
    end

    # Returns the stat hash for entry_path if it passes every filter, nil
    # otherwise. stat_or_errno is the entry's upfront lstat outcome (see
    # EntryStat).
    private def match(entry_path : String, stat_or_errno : EntryStat, options : Options, skipped_paths : Hash(String, JSON::Any), warnings : Array(String)) : Hash(String, JSON::Any)?
      # Real find lstats EVERY walked entry before any pattern filtering
      # and turns a failing lstat into a per-entry skip, not a silent
      # drop: the entry is dropped from the results, recorded in
      # skipped_paths under its OWN path with the OSError str() text and
      # warned about (error_as_warning's chain rendering is
      # "Skipped entry '<path>' due to access issue: <errno text>",
      # live-verified vs 2.19.11 with a read-but-no-execute directory),
      # and has_warnings flips the result msg (see execute). The pattern
      # filters run AFTER the stat in real, so a failing lstat warns even
      # when the basename would not have matched. claranet.log4shell's
      # recursive scan of / trips this on vanishing /proc/<pid>/fd/*
      # symlinks (ENOENT) - krikri previously swallowed the failure
      # without any warning.
      if stat_or_errno.is_a?(Errno)
        text = errno_text(entry_path, stat_or_errno)
        skipped_paths[entry_path] = JSON::Any.new(text)
        warnings << "Skipped entry '#{entry_path}' due to access issue: #{text}"
        return nil
      end
      stat_hash = stat_or_errno
      return nil unless stat_hash.is_a?(Hash(String, JSON::Any))

      basename = File.basename(entry_path)
      return nil unless matches_patterns?(basename, options.patterns, options.use_regex)
      return nil if !options.excludes.empty? && matches_patterns?(basename, options.excludes, options.use_regex)
      return nil unless matches_file_type?(stat_hash, options.file_type)
      return nil unless matches_size?(stat_hash, options.size_filter)
      return nil unless matches_age?(stat_hash, options.age_filter, options.age_stamp, options.now)
      return nil if options.file_type == "file" && !matches_contains?(entry_path, options.contains, options.read_whole_file, options.encoding)
      return nil if (mode = options.mode) && !PluginHelpers::FindModeFilter.matches?(stat_hash["mode"].as_s.to_i(8), mode, options.exact_mode)

      add_symlink_fields(stat_hash, entry_path) if stat_hash["islnk"].as_bool
      add_checksum(stat_hash, entry_path, options.algorithm) if options.get_checksum && stat_hash["isreg"].as_bool

      # Real find's per-file dicts are a REDUCED stat shape - no `exists`
      # (every listed file exists by construction), no block_size/blocks/
      # device_type (live-verified vs 2.19.11 at -v; the full shape is
      # the stat module's own output, which find's docs point at but
      # do not reproduce).
      stat_hash.delete("exists")
      stat_hash.delete("block_size")
      stat_hash.delete("blocks")
      stat_hash.delete("device_type")

      reorder_stat_owners_after_ctime(stat_hash)
    end

    # The stat field table is shared with the stat module, whose shape keeps
    # gr_name/pw_name at the tail; real find's per-file dicts instead place
    # them immediately after ctime, so find alone reorders rather than
    # disturbing the shared table's own order.
    private def reorder_stat_owners_after_ctime(stat_hash : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      gr_name = stat_hash["gr_name"]?
      pw_name = stat_hash["pw_name"]?
      return stat_hash unless stat_hash["ctime"]? && gr_name && pw_name

      ordered = Hash(String, JSON::Any).new
      stat_hash.each do |key, value|
        next if key == "gr_name" || key == "pw_name"
        ordered[key] = value
        if key == "ctime"
          ordered["gr_name"] = gr_name
          ordered["pw_name"] = pw_name
        end
      end
      ordered
    end

    # Lists every path under search_path (not including search_path
    # itself) up to the given depth - direct children are depth 1,
    # matching real `find <path> -mindepth 1 -maxdepth N`'s own
    # numbering, which this replaces. Symlinked directories are descended
    # into only when follow: true, matching Ansible's own
    # os.walk(followlinks=...) - with follow: false (the default) the
    # symlink itself is still listed/examined (os.walk puts it in `dirs`
    # either way), just not walked into. Unreadable directories are
    # skipped silently rather than failing the whole search, matching the
    # previous shell implementation's `2>/dev/null`.
    private def list_entries(search_path : String, options : Options, skipped_paths : Hash(String, JSON::Any)) : Array(Tuple(String, EntryStat))
      max_depth = if !options.recurse
                    1
                  elsif depth = options.depth
                    depth
                  else
                    Int32::MAX
                  end

      entries = [] of Tuple(String, EntryStat)
      walk(search_path, 1, max_depth, options, entries, skipped_paths)
      entries
    end

    private def walk(dir : String, current_depth : Int32, max_depth : Int32, options : Options, entries : Array(Tuple(String, EntryStat)), skipped_paths : Hash(String, JSON::Any)) : Nil
      return if current_depth > max_depth

      Dir.each_child(dir) do |child|
        child_path = File.join(dir, child)
        # The upfront lstat the entry itself is classified with - the
        # previous stat(File.directory?)+lstat(File.symlink?) pair cost
        # two syscalls per entry and its stat EACCES-aborted the whole
        # level on a read-but-no-execute directory, recording the PARENT's
        # path in skipped_paths where real find keeps walking.
        stat_or_errno = native_stat_ex(child_path, false)
        entries << {child_path, stat_or_errno}

        # Descend decision off the same upfront lstat the entry itself is
        # classified with - the previous stat(File.directory?)+
        # lstat(File.symlink?) pair cost two syscalls per entry and its
        # stat EACCES-aborted the whole level on a read-but-no-execute
        # directory, recording the PARENT's path in skipped_paths where
        # real find keeps walking. A symlink child needs one
        # target-following stat to learn it points at a directory (the
        # old File.directory? semantics): with follow: true it is
        # descended into, with follow: false it stays
        # listed-but-unwalked - follow only widens the walk, never
        # re-classifies a symlink as its target type.
        if (stat = stat_or_errno).is_a?(Hash(String, JSON::Any))
          descend = if stat["islnk"].as_bool
                      options.follow && File.directory?(child_path)
                    else
                      stat["isdir"].as_bool
                    end
          if descend
            walk(child_path, current_depth + 1, max_depth, options, entries, skipped_paths)
          end
        end
      end
    rescue ex : File::Error
      # Ansible's os.walk(onerror=handle_walk_errors) - live-verified vs
      # 2.19.11: an unreadable directory is NOT a silent skip and NOT a
      # failure. EPERM/EACCES/ENOENT are recorded in skipped_paths under
      # the UNLISTABLE directory's own path with Python's OSError str()
      # text ("[Errno 13] Permission denied: '<path>'"), swallowed
      # silently - no warning, msg stays "All paths examined", the
      # registered result carries no warnings key. Any other errno
      # re-raises out of os.walk into the per-search-path handler, which
      # records the TOP search path and warns (WalkError).
      case ex.os_error
      when Errno::EACCES, Errno::EPERM, Errno::ENOENT
        skipped_paths[dir] = JSON::Any.new(os_error_text(dir, ex))
      else
        raise WalkError.new(os_error_text(dir, ex))
      end
    end

    # Python's OSError str(): "[Errno 13] Permission denied: '/path'".
    private def errno_text(path : String, errno : Errno) : String
      "[Errno #{errno.value}] #{errno.message}: '#{path}'"
    end

    private def os_error_text(path : String, ex : File::Error) : String
      if errno = ex.os_error
        "[Errno #{errno.value}] #{errno.message}: '#{path}'"
      else
        "[Errno 0] #{ex.message}: '#{path}'"
      end
    end

    # True if any path component between search_path and entry_path starts
    # with "." - Ansible (os.walk-based) never descends into a hidden
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
    # (now - timestamp <= abs(age)) - verified against Ansible's own
    # find.py agefilter() source, not guessed from the docs' prose.
    private def matches_age?(stat_hash : Hash(String, JSON::Any), age_filter : String?, age_stamp : String, now : Int64) : Bool
      return true unless age_filter

      age = parse_age(age_filter)
      return true unless age

      # atime/mtime/ctime are float seconds now (matching Python's
      # st_atime etc. that Ansible carries through) - elapsed is
      # compared as float, same result at whole-second age granularity.
      timestamp = stat_hash[age_stamp]?.try(&.as_f) || stat_hash["mtime"].as_f
      elapsed = now.to_f - timestamp
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

    # contains: only applies to regular files (Ansible's own
    # restriction: "Works only when file_type is file" - the caller
    # already gates this on file_type == "file"). read_whole_file: false
    # (the default) matches line-by-line, anchored at the start of each
    # line - Python's re.match() semantics, which \A (not multiline ^)
    # replicates in Crystal's PCRE-based Regex; read_whole_file: true
    # searches anywhere in the whole file content (Python's re.search()).
    # A read failure (permission denied, a regex that can't compile, etc.)
    # is treated as no match, same as Ansible's own broad `except
    # Exception: pass` around this - but a DECODE failure is not one:
    # real opens the file as text (see read_decoded) and lets the decode
    # error abandon the whole search path, so it propagates out of here.
    private def matches_contains?(path : String, contains : String?, read_whole_file : Bool, encoding : String?) : Bool
      return true unless contains

      pattern = Regex.new(contains)
      if read_whole_file
        !!(read_decoded(path, encoding) =~ pattern)
      else
        anchored = Regex.new("\\A(?:#{contains})")
        any_line_matches?(path, encoding, anchored)
      end
    rescue File::Error | Regex::Error
      false
    end

    # `contains:`'s own file reading. Real find.py opens the file as
    # text (`open(fsname, encoding=encoding)`) - with no explicit
    # encoding: that is Python's default codec (UTF-8 on every Linux
    # environment ansible-core's modules run in) at its default strict
    # error handling, so an undecodable byte raises UnicodeDecodeError,
    # which contentfilter converts into the per-search-path skip
    # (raise_decode_error below). krikri previously read such files as
    # raw bytes and matched latin-1-style instead, silently matching
    # through files real refuses to read at all (issue #893: a git
    # object file warned on real's stderr while krikri stayed silent).
    #
    # Encoding affects ONLY this path: get_checksum hashes raw bytes
    # via digest_from_file regardless of encoding.
    private def read_decoded(path : String, encoding : String?) : String
      raw = File.read(path)
      unless encoding
        raise_decode_error(path, encoding) unless raw.valid_encoding?
        return raw
      end

      case normalize_encoding(encoding)
      when "UTF-8"
        # read_whole_file: true reads the entire file (f.read()) before
        # searching, so the first undecodable byte anywhere wins, match
        # or not.
        raise_decode_error(path, encoding) unless raw.valid_encoding?
        raw
      when "ASCII"
        raise_decode_error(path, encoding) unless raw.ascii_only?
        raw
      when "ISO-8859-1"
        # Latin-1 cannot produce a decode error - every byte maps to the
        # same codepoint - which is exactly why real cannot hit one with
        # it either.
        raw.bytes.map(&.chr).join
      else
        begin
          File.open(path) do |file|
            file.set_encoding(normalize_encoding(encoding), invalid: :skip)
            file.gets_to_end
          end
        rescue ArgumentError
          # Python's LookupError text; find.py re-raises LookupError
          # untouched and the per-path `except Exception` abandons the
          # whole search path with this as the skip reason
          raise UnknownEncoding.new("unknown encoding: #{encoding}")
        end
      end
    end

    # Line-by-line contains: matching. The strict codecs (default/UTF-8,
    # ASCII) reproduce real's decode timing below; latin-1 and the exotic
    # codecs cannot produce a decode error here (latin-1 accepts every
    # byte, the exotic path skips invalid ones), so they simply iterate
    # the decoded text's lines.
    private def any_line_matches?(path : String, encoding : String?, anchored : Regex) : Bool
      if encoding.nil? || {"UTF-8", "ASCII"}.includes?(normalize_encoding(encoding))
        return any_strict_line_matches?(path, encoding, anchored)
      end
      read_decoded(path, encoding).each_line.any?(&.matches?(anchored))
    end

    # Real's TextIOWrapper decodes the file in 8192-byte chunks
    # (io.TextIOWrapper._CHUNK_SIZE) and yields lines only from chunks
    # that decoded whole: an undecodable byte anywhere in a chunk makes
    # the whole chunk fail before ANY of its lines is yielded, while a
    # match from an earlier, fully-decoded chunk is returned before the
    # bad chunk is ever read. Reproduced closed-form: the first
    # undecodable byte pins the first bad chunk; only lines terminating
    # before that chunk's start may match; reaching the bad chunk raises
    # the per-search-path skip (a sequence truncated at EOF errors the
    # same way - its start byte sits in the final chunk).
    private CHUNK_SIZE = 8192

    private def any_strict_line_matches?(path : String, encoding : String?, anchored : Regex) : Bool
      content = File.read(path)
      ascii = !encoding.nil? && normalize_encoding(encoding) == "ASCII"
      if bad = first_decode_error(content, ascii)
        limit = (bad // CHUNK_SIZE) * CHUNK_SIZE
        unless limit.zero?
          # Every byte before the first undecodable one decoded clean,
          # and a sequence cut at the boundary holds only continuation
          # bytes (all >= 0x80), so the terminated lines inside the
          # prefix are clean text; the unterminated tail is not yielded
          # by real either - its newline needs the bad chunk decoded
          # first.
          content.byte_slice(0, limit).each_line(chomp: false) do |line|
            next unless line.ends_with?('\n') || line.ends_with?('\r')
            return true if line.matches?(anchored)
          end
        end
        raise_decode_error(path, encoding)
      end
      content.each_line.any?(&.matches?(anchored))
    end

    # The byte offset of the first byte Python's strict decoder rejects -
    # the UTF-8 codec's rules (stray continuation bytes, overlong forms,
    # surrogate halves and > U+10FFFF sequences are all errors), or plain
    # 7-bit ASCII bounds for encoding: ascii - nil when everything
    # decodes.
    private def first_decode_error(content : String, ascii : Bool) : Int32?
      size = content.bytesize
      if ascii
        i = 0
        while i < size
          return i if content.byte_at(i) >= 0x80
          i += 1
        end
        return nil
      end

      i = 0
      while i < size
        lead = content.byte_at(i)
        if lead < 0x80
          i += 1
          next
        end
        span, lo, hi = case lead
                       when 0xC2..0xDF then {2, 0x80, 0xBF}
                       when 0xE0       then {3, 0xA0, 0xBF}
                       when 0xE1..0xEC then {3, 0x80, 0xBF}
                       when 0xED       then {3, 0x80, 0x9F}
                       when 0xEE..0xEF then {3, 0x80, 0xBF}
                       when 0xF0       then {4, 0x90, 0xBF}
                       when 0xF1..0xF3 then {4, 0x80, 0xBF}
                       when 0xF4       then {4, 0x80, 0x8F}
                       else                 return i
                       end
        return i if i + span > size
        return i unless lo <= content.byte_at(i + 1) <= hi
        (2...span).each do |offset|
          return i unless 0x80 <= content.byte_at(i + offset) <= 0xBF
        end
        i += span
      end
      nil
    end

    # contentfilter's UnicodeDecodeError conversion - the exact skip
    # reason real records for the search path and warns with (fsname
    # unquoted; encoding None names open()'s locale-default codec).
    private def raise_decode_error(path : String, encoding : String?) : NoReturn
      shown = encoding || "None (default determined by the Python built-in function \"open\")"
      raise UnknownEncoding.new("Failed to read the file #{path} due to an encoding error. current encoding: #{shown}")
    end

    # Accepts Python's codec alias spellings ("latin-1", "utf8", "us-ascii")
    # as Ansible's `open(encoding=...)` does - Crystal's iconv-based
    # set_encoding only knows the canonical names ("ISO-8859-1", "UTF-8",
    # "ASCII"), so the common lowercase aliases are mapped across.
    private def normalize_encoding(name : String) : String
      case name.downcase
      when "latin-1", "latin1", "iso8859-1", "iso_8859-1" then "ISO-8859-1"
      when "utf-8", "utf8"                                then "UTF-8"
      when "us-ascii", "ascii"                            then "ASCII"
      else                                                     name
      end
    end

    private def add_symlink_fields(stat_hash : Hash(String, JSON::Any), path : String) : Nil
      raw_target = File.readlink(path)
      resolved_target = begin
        File.realpath(path)
      rescue
        raw_target
      end

      stat_hash["lnk_target"] = JSON::Any.new(raw_target)
      stat_hash["lnk_source"] = JSON::Any.new(resolved_target)
    end

    private def add_checksum(stat_hash : Hash(String, JSON::Any), path : String, algorithm : String) : Nil
      stat_hash["checksum"] = JSON::Any.new(native_checksum(path, algorithm))
    rescue File::Error
      # A checksum failure (e.g. permission denied) just omits the field
      # rather than dropping the whole match.
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::FindPlugin.new(config)
plugin.run
