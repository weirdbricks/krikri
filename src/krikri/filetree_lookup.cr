require "json"
require "./plugin_helpers/facts_gatherer"

# Krikri::FiletreeLookup - a native reimplementation of the
# community.general.filetree lookup plugin (with_community.general.filetree:),
# translated from `community.general/plugins/lookup/filetree.py` (verified
# against the collection source, not guessed).
#
# Real semantics (all load-bearing for the roles that use it):
#   - Each term is a directory to walk RECURSIVELY, top-down. Entries are
#     yielded one per file OR subdirectory at every depth - directories
#     first, then files, per level - each as a dict of stat properties.
#   - `path` is relative to the walked root; `root` is the walked root
#     itself. Multiple terms implement a first-found-ish dedup: a relative
#     path already yielded by an earlier root is skipped.
#   - `state` is 'directory' / 'file' / 'link' (lstat semantics - the
#     walk never follows symlinks, matching os.walk's default). `src` is
#     present ONLY for 'file' (the absolute path) and 'link' (the raw
#     readlink target) - a directory entry has no `src` key at all, which
#     is exactly what roles' `when: item.state == 'file'` gating leans on.
#   - `mode` is the 4-char octal string ("0" + 3 octal digits, e.g.
#     "0644"); owner/group resolve to NAMES (falling back to the raw
#     uid/gid when the id has no passwd/group entry); mtime/ctime are
#     epoch floats.
#
# A missing root yields no entries rather than failing - os.walk of a
# nonexistent path simply yields nothing, and real Ansible passes that
# empty list straight through (a fully-empty loop skips the task; it is
# never an error).
#
# Missing entirely before - buluma.vector's own "config | Create templates
# config skeleton" task (`with_community.general.filetree:` +
# `when: item.state == 'directory'`) had `with_community.general.filetree`
# silently fall through as an unrecognized task key, so `item` was never
# bound and the when: raised "'item.state' is undefined" instead of
# iterating the tree (round 300054's warm divergence).
module Krikri::FiletreeLookup
  # Lib bindings, mostly aliased to unique Crystal-side names: lib funs
  # are effectively global in Crystal (the check keys on the C symbol,
  # not the fun name), and a second declaration of getpwuid already
  # exists at top level - `PASSWD::getpwuid` in
  # `plugin_helpers/facts_gatherer.cr`, required (and reused directly)
  # above, with a struct of identical layout, verified against
  # getpwuid(3). getgrgid and lstat have no other declaration anywhere,
  # but get the same alias treatment for consistency. lstat is needed
  # raw because File::Info surfaces no ctime and no numeric uid/gid,
  # and file_props needs the raw uid/gid/mode/mtime/ctime tuple exactly
  # like os.lstat.
  lib LibFT
    struct FTGroup
      gr_name : UInt8*
      gr_passwd : UInt8*
      gr_gid : UInt32
      gr_mem : UInt8**
    end

    fun ft_getgrgid = getgrgid(gid : UInt32) : FTGroup*
    fun ft_lstat = lstat(path : UInt8*, buf : LibC::Stat*) : LibC::Int
  end

  # Resolves each source (a raw, already-{{ }}-substituted directory path)
  # to a walked root, walks it, and returns the combined entry list in
  # real filetree's own yield order. *role_path* (the current role's
  # root, when the task runs inside a role) is what a RELATIVE source
  # resolves against - real Ansible's lookup dwims relative paths through
  # path_dwim_relative(basedir, 'files', ...), which for a role task
  # means the role's own files/ directory; an absolute source (the
  # overwhelmingly common form - `{{ role_path }}/templates/config/` and
  # friends) is used as-is.
  def self.resolve(sources : Array(String), role_path : String?) : Array(Hash(String, JSON::Any))
    entries = [] of Hash(String, JSON::Any)
    seen_paths = Set(String).new

    sources.each do |raw|
      root = resolve_root(raw.strip, role_path)
      next unless root
      walk(root, "", entries, seen_paths)
    end

    entries
  end

  private def self.resolve_root(source : String, role_path : String?) : String?
    return source if source.starts_with?('/')
    return nil unless role_path

    # Real dwim checks the role's files/ dir first; fall back to the role
    # root itself for the `{% raw %}`-style sources that live elsewhere
    # under the role. First EXISTING candidate wins; a source that exists
    # nowhere still returns the primary candidate so the walk below
    # yields the same empty result os.walk would.
    candidates = [File.join(role_path, "files", source), File.join(role_path, source)]
    found = candidates.find { |candidate| Dir.exists?(candidate) }
    found || candidates.first
  end

  # Mirrors os.walk(path, topdown=True) exactly as the real lookup's
  # `for root, dirs, files in os.walk(...)` consumes it: every entry of
  # the CURRENT level (directories first, then files) is yielded before
  # ANY descent - a recursive-descent walk would emit
  # subdir/nested.conf before a top-level sibling, which os.walk never
  # does (it queues subdirs and processes them in order).
  #
  # The dedup check (real filetree.py: `if relpath not in [entry["path"]
  # for entry in ret]`) skips only the ENTRY - os.walk still descends
  # into a directory whose own relpath was already yielded by an earlier
  # root, so a later root's unique children (e.g. common/b.conf under a
  # common/ dir first seen under root_a) DO come through.
  private def self.walk(root : String, rel : String, entries : Array(Hash(String, JSON::Any)), seen : Set(String)) : Nil
    queue = [rel]
    loop do
      current = queue.shift? || break
      dir = current.empty? ? root : File.join(root, current)
      next unless Dir.exists?(dir)

      # os.walk makes no ordering guarantee, but every real consumer
      # either gates on state or sorts downstream - deterministic
      # (sorted) order here keeps renders reproducible without changing
      # any real behavior.
      subdirs = [] of String
      Dir.children(dir).sort!.each do |child|
        child_rel = current.empty? ? child : File.join(current, child)
        state = entry_state(File.join(dir, child))
        next if state.empty?

        subdirs << child_rel if state == "directory"

        next if seen.includes?(child_rel)
        seen << child_rel

        if props = file_props(root, child_rel, File.join(dir, child))
          entries << props
        end
      end

      queue.concat(subdirs)
    end
  end

  # lstat-based state of a single path (never follows symlinks, matching
  # os.walk's own default); "" for anything unsupported/stat-failed.
  private def self.entry_state(path : String) : String
    stat = LibC::Stat.new
    return "" unless LibFT.ft_lstat(path, pointerof(stat)) == 0

    case stat.st_mode & LibC::S_IFMT
    when LibC::S_IFLNK then "link"
    when LibC::S_IFDIR then "directory"
    when LibC::S_IFREG then "file"
    else                    ""
    end
  end

  # Translated from filetree.py's own file_props(): lstat the entry, map
  # its type to state (+ src for file/link), and attach the stat
  # properties. A failed stat yields nil (real module warns and skips).
  private def self.file_props(root : String, relpath : String, abspath : String) : Hash(String, JSON::Any)?
    stat = LibC::Stat.new
    return nil unless LibFT.ft_lstat(abspath, pointerof(stat)) == 0

    mode = stat.st_mode
    is_link = (mode & LibC::S_IFMT) == LibC::S_IFLNK
    is_dir = (mode & LibC::S_IFMT) == LibC::S_IFDIR
    is_reg = (mode & LibC::S_IFMT) == LibC::S_IFREG

    state = if is_link
              "link"
            elsif is_dir
              "directory"
            elsif is_reg
              "file"
            else
              # real module warns "file type is not supported" and skips
              return nil
            end

    props = {
      "root"  => JSON::Any.new(root),
      "path"  => JSON::Any.new(relpath),
      "state" => JSON::Any.new(state),
      "uid"   => JSON::Any.new(stat.st_uid.to_i64),
      "gid"   => JSON::Any.new(stat.st_gid.to_i64),
      "owner" => owner_name(stat.st_uid),
      "group" => group_name(stat.st_gid),
      "mode"  => JSON::Any.new(sprintf("0%03o", mode & 0o777)),
      "size"  => JSON::Any.new(stat.st_size.to_i64),
      "mtime" => JSON::Any.new(timespec_to_f(stat_mtime_ts(stat))),
      "ctime" => JSON::Any.new(timespec_to_f(stat_ctime_ts(stat))),
    } of String => JSON::Any

    case state
    when "file"
      props["src"] = JSON::Any.new(abspath)
    when "link"
      props["src"] = JSON::Any.new(File.readlink(abspath))
    end

    props
  end

  private def self.timespec_to_f(ts : LibC::Timespec) : Float64
    ts.tv_sec.to_f + ts.tv_nsec / 1e9
  end

  # LibC::Stat's timestamp field names are libc-specific (st_mtim/st_ctim
  # on glibc/Linux, st_mtimespec/st_ctimespec on Darwin), same split
  # Krikri.stat_atime_sec et al. in base_plugin.cr already handle.
  private def self.stat_mtime_ts(stat : LibC::Stat) : LibC::Timespec
    {% if flag?(:darwin) %}
      stat.st_mtimespec
    {% else %}
      stat.st_mtim
    {% end %}
  end

  private def self.stat_ctime_ts(stat : LibC::Stat) : LibC::Timespec
    {% if flag?(:darwin) %}
      stat.st_ctimespec
    {% else %}
      stat.st_ctim
    {% end %}
  end

  private def self.owner_name(uid : LibC::UidT) : JSON::Any
    if pw = PASSWD.getpwuid(uid.to_u32)
      name = String.new(pw.value.pw_name)
      return JSON::Any.new(name) unless name.empty?
    end
    JSON::Any.new(uid.to_i64)
  rescue
    JSON::Any.new(uid.to_i64)
  end

  private def self.group_name(gid : LibC::GidT) : JSON::Any
    if gr = LibFT.ft_getgrgid(gid.to_u32)
      name = String.new(gr.value.gr_name)
      return JSON::Any.new(name) unless name.empty?
    end
    JSON::Any.new(gid.to_i64)
  rescue
    JSON::Any.new(gid.to_i64)
  end
end
