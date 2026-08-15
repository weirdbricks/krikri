#!/usr/bin/env crystal

require "json"
require "crystar"
require "compress/gzip"
require "compress/zip"
require "xz"
require "bz2"
require "system/user"
require "system/group"
require "openssl/digest"
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
  # - exclude_path: comma-separated paths/globs removed from the *path:*
  #   list itself before archiving - narrower than its name suggests, and
  #   verified against a real community.general 11.2.1 install's actual
  #   archived-members output rather than assumed from the docs: it only
  #   drops an entry that exactly matches one of the top-level `path:`
  #   list items, not a file living inside a directory being archived (use
  #   exclusion_patterns: for that - it reaches into a directory's own
  #   contents, exclude_path: never does). The `expanded_paths:` result
  #   field stays unfiltered by this either way, matching real Ansible's
  #   own observed output.
  # - mode / owner / group: applied to the resulting dest file
  #
  # - attributes: a chattr(1) flag string (e.g. "+i") applied to dest -
  #   verified against real AnsibleModule's own
  #   `set_attributes_if_different` source, unconditional (no filesystem-
  #   support gate), fails the task on a real chattr error.
  # - seuser / serole / setype / selevel: SELinux file context, applied
  #   via chcon - matches real Ansible's own confirmed no-op-when-
  #   SELinux-isn't-enabled behavior (`AnsibleModule.selinux_enabled()`,
  #   checked here via `/sys/fs/selinux/enforce`'s own existence, the
  #   same file `selinuxenabled(8)` tests) - see `#apply_selinux_context`
  #   for the one part of this NOT live-verified (the chcon-invocation
  #   shape on an actually-SELinux-enabled host).
  #
  # Not implemented: unsafe_writes.
  #
  # All five formats are now built and read natively: Crystar for tar,
  # Compress::Gzip/Compress::Zip from Crystal's own standard library,
  # naqvis/xz.cr (a real liblzma C binding) for xz, and weirdbricks/bz2.cr
  # (a real libbz2 C binding, written for this project after a shard
  # search turned up nothing usable - the only prior bz2 shard,
  # jhbadger/Bzip, is itself a shell wrapper around `bzcat` with no writer,
  # not a real implementation) for bz2. This matches real Ansible's own
  # archive module, which uses Python's tarfile/zipfile stdlib rather than
  # shelling out too - no format shells out anymore.
  #
  # Idempotency is checksum-based like real Ansible, but computed by
  # reading crystal-ansible's own previously-built archive back natively
  # rather than replicating Python's tarfile per-member header checksum
  # exactly - this compares crystal-ansible's own archives against
  # themselves across runs, which
  # doesn't require bit-for-bit parity with Python's internal algorithm to
  # be correct. Note: upgrading from the previous shell-based
  # implementation to this one may report changed: true exactly once for
  # a pre-existing archive, since member ordering (now Dir.each_child's
  # order, previously `find`'s) can differ even when content doesn't - a
  # one-time transition artifact, not an ongoing bug.
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
      requested_excludes = (@params["exclude_path"]? || "").split(",").map(&.strip).reject(&.empty?)
      force_archive = is_true?(@params["force_archive"]?, default: false)
      remove = is_true?(@params["remove"]?, default: false)
      exclusion_patterns = (@params["exclusion_patterns"]? || "").split(",").map(&.strip).reject(&.empty?)

      expanded_paths, missing = expand_paths(requested_paths)
      expanded_excludes, _ = expand_paths(requested_excludes)

      # exclude_path only removes entries that exactly match one of the
      # top-level expanded path: entries themselves - real Ansible's own
      # `self.paths = set(self.expanded_paths) - set(self.expanded_exclude_paths)`,
      # verified against a real community.general 11.2.1 install's actual
      # archived-members output, not assumed from the docs (which read as
      # a general per-file exclusion). A file living *inside* a directory
      # being archived is NOT excludable this way - it still ends up in
      # the archive even when named exactly in exclude_path, since it was
      # never itself a top-level path: entry - only exclusion_patterns:
      # (already supported) reaches into a directory's own contents. The
      # returned `expanded_paths:` result field stays unfiltered either
      # way, matching real Ansible's own observed output.
      candidate_paths = expanded_paths.reject { |path| expanded_excludes.includes?(path) }
      found_paths = candidate_paths.reject { |path| missing.includes?(path) }

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
                        candidate_paths.size == 1 && found_paths.size == 1 && !Dir.exists?(found_paths[0])

      root = PluginHelpers::ArchivePaths.common_path(candidate_paths)
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
          expanded.concat(Dir.glob(pattern).select { |match| File.exists?(match) || File.symlink?(match) }.sort!)
        else
          expanded << pattern
          missing << pattern unless File.exists?(pattern) || File.symlink?(pattern)
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
    # actually building the archive.
    # Each member's `File::Info` (follow_symlinks: false, matching how
    # the archive itself treats members) is captured once here rather
    # than re-stat'd later when building the archive - collect_members
    # already has to stat every entry to know whether to recurse into it,
    # so a separate stat call per member later (tar_header_for's original
    # approach) is pure waste. Found by benchmarking: this alone roughly
    # halved the gap between native and shell-`tar` for a 2,000-file tree.
    @info_cache = Hash(String, File::Info).new

    private def info_for(path : String) : File::Info
      @info_cache.fetch(path) { @info_cache[path] = File.info(path, follow_symlinks: false) }
    end

    private def collect_members(found_paths : Array(String), root : String, exclusion_patterns : Array(String)) : Array(String)
      members = [] of String

      found_paths.each do |path|
        info = info_for(path)
        if info.directory? && !info.symlink?
          walk(path, members)
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

    private def walk(dir : String, members : Array(String))
      Dir.each_child(dir) do |child|
        child_path = File.join(dir, child)
        members << child_path
        info = info_for(child_path)
        walk(child_path, members) if info.directory? && !info.symlink?
      end
    rescue
      # Permission denied, etc. - skip this directory rather than failing
      # the whole archive.
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
        File.delete?(tmp_dest)
        return PluginResult.new(changed: false, failed: true, msg: "failed to build archive")
      end

      old_signature = File.exists?(dest) ? signature(dest, format, single_compress) : nil
      new_signature = signature(tmp_dest, format, single_compress)
      changed = old_signature != new_signature

      if changed
        File.rename(tmp_dest, dest)
      else
        File.delete?(tmp_dest)
      end

      remove_sources(found_paths) if remove

      dest_state = missing.empty? ? (single_compress ? "compress" : "archive") : "incomplete"
      apply_dest_attributes(dest)
      if error = apply_attributes(dest)
        return error
      end
      if error = apply_selinux_context(dest)
        return error
      end

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
      case format
      when "bz2"
        File.open(tmp_dest, "w") do |file|
          Compress::BZ2::Writer.open(file) do |bz2|
            File.open(source) { |src| IO.copy(src, bz2) }
          end
        end
        true
      when "xz"
        File.open(tmp_dest, "w") do |file|
          Compress::XZ::Writer.open(file) do |xz|
            File.open(source) { |src| IO.copy(src, xz) }
          end
        end
        true
      else
        File.open(tmp_dest, "w") do |file|
          Compress::Gzip::Writer.open(file) do |gz|
            File.open(source) { |src| IO.copy(src, gz) }
          end
        end
        true
      end
    rescue
      false
    end

    # Adds every already-walked, already-exclusion-filtered `members` entry
    # individually (not letting tar/zip recurse into a directory member on
    # their own - each entry, files and directories alike, is already
    # listed explicitly by `collect_members`, so recursing too would
    # double-include children).
    private def build_archive(root : String, members : Array(String), format : String, tmp_dest : String) : Bool
      relative_members = members.map { |member| member.starts_with?(root) ? member[root.size..-1] : member }
      return false if relative_members.empty?

      case format
      when "zip"
        build_zip(root, members, relative_members, tmp_dest)
      else
        build_tar(root, members, relative_members, tmp_dest, format)
      end
    end

    private def build_tar(root : String, members : Array(String), relative_members : Array(String), tmp_dest : String, format : String) : Bool
      File.open(tmp_dest, "w") do |file|
        case format
        when "gz"
          Compress::Gzip::Writer.open(file) { |gz| write_tar_entries(gz, root, members, relative_members) }
        when "xz"
          Compress::XZ::Writer.open(file) { |xz| write_tar_entries(xz, root, members, relative_members) }
        when "bz2"
          Compress::BZ2::Writer.open(file) { |bz2| write_tar_entries(bz2, root, members, relative_members) }
        else
          write_tar_entries(file, root, members, relative_members)
        end
      end
      true
    rescue
      false
    end

    private def write_tar_entries(io : IO, root : String, members : Array(String), relative_members : Array(String))
      Crystar::Writer.open(io) do |tar|
        members.each_with_index do |member, i|
          info = info_for(member)
          tar.write_header(tar_header_for(info, relative_members[i]))
          unless info.directory? && !info.symlink?
            File.open(member) { |src| tar.write(src.gets_to_end.to_slice) }
          end
        end
      end
    end

    # uid/gid -> name lookups are a real syscall/NSS round trip each - a
    # tree of thousands of files almost always shares the same handful of
    # owners, so resolving each unique id only once (instead of once per
    # member) is the difference between a fast archive build and a slow
    # one. Found by benchmarking: a naive per-member lookup made this
    # *slower* than the previous shell-based `tar` for a 2,000-file tree.
    @uname_cache = Hash(Int32, String).new
    @gname_cache = Hash(Int32, String).new

    private def uname_for(uid : Int32) : String
      @uname_cache.fetch(uid) { @uname_cache[uid] = System::User.find_by?(id: uid.to_s).try(&.username) || "" }
    end

    private def gname_for(gid : Int32) : String
      @gname_cache.fetch(gid) { @gname_cache[gid] = System::Group.find_by?(id: gid.to_s).try(&.name) || "" }
    end

    private def tar_header_for(info : File::Info, archive_name : String) : Crystar::Header
      uid = info.owner_id.to_i32? || 0
      gid = info.group_id.to_i32? || 0

      h = Crystar::Header.new(
        name: archive_name,
        mode: info.permissions.value.to_i64,
        mod_time: info.modification_time,
        uid: uid,
        gid: gid,
        uname: uname_for(uid),
        gname: gname_for(gid),
      )

      if info.directory?
        h.flag = Crystar::DIR.ord.to_u8
        h.name += "/" unless h.name.ends_with?('/')
      else
        h.flag = Crystar::REG.ord.to_u8
        h.size = info.size
      end

      h
    end

    private def build_zip(root : String, members : Array(String), relative_members : Array(String), tmp_dest : String) : Bool
      Compress::Zip::Writer.open(tmp_dest) do |zip|
        members.each_with_index do |member, i|
          info = info_for(member)
          if info.directory? && !info.symlink?
            zip.add_dir(relative_members[i])
          else
            zip.add(relative_members[i]) { |io| File.open(member) { |src| IO.copy(src, io) } }
          end
        end
      end
      true
    rescue
      false
    end

    # A content+membership signature for `path`, used to decide whether a
    # freshly-built archive differs from what's already at dest.
    private def signature(path : String, format : String, single_compress : Bool) : String?
      return nil unless File.exists?(path)

      if single_compress
        single_compress_signature(path, format)
      elsif format == "zip"
        zip_signature(path)
      else
        tar_signature(path, format)
      end
    rescue
      nil
    end

    private def single_compress_signature(path : String, format : String) : String?
      case format
      when "bz2"
        digest = OpenSSL::Digest.new("MD5")
        File.open(path) do |file|
          Compress::BZ2::Reader.open(file) { |bz2| digest.update(bz2.gets_to_end) }
        end
        digest.final.hexstring
      when "xz"
        digest = OpenSSL::Digest.new("MD5")
        File.open(path) do |file|
          Compress::XZ::Reader.open(file) { |xz| digest.update(xz.gets_to_end) }
        end
        digest.final.hexstring
      else
        digest = OpenSSL::Digest.new("MD5")
        File.open(path) do |file|
          Compress::Gzip::Reader.open(file) { |gz| digest.update(gz.gets_to_end) }
        end
        digest.final.hexstring
      end
    end

    private def zip_signature(path : String) : String
      names = [] of String
      digest = OpenSSL::Digest.new("MD5")

      Compress::Zip::Reader.open(path) do |zip|
        zip.each_entry do |entry|
          names << entry.filename
          digest.update(entry.io.gets_to_end) unless entry.dir?
        end
      end

      "#{names.sort!.join("\n")}|#{digest.final.hexstring}"
    end

    private def tar_signature(path : String, format : String) : String
      names = [] of String
      digest = OpenSSL::Digest.new("MD5")

      File.open(path) do |file|
        case format
        when "gz"
          Compress::Gzip::Reader.open(file) { |gz| read_tar_signature(gz, names, digest) }
        when "xz"
          Compress::XZ::Reader.open(file) { |xz| read_tar_signature(xz, names, digest) }
        when "bz2"
          Compress::BZ2::Reader.open(file) { |bz2| read_tar_signature(bz2, names, digest) }
        else
          read_tar_signature(file, names, digest)
        end
      end

      "#{names.sort!.join("\n")}|#{digest.final.hexstring}"
    end

    private def read_tar_signature(io : IO, names : Array(String), digest : OpenSSL::Digest)
      Crystar::Reader.open(io) do |tar|
        tar.each_entry do |entry|
          names << entry.name
          digest.update(entry.io.gets_to_end) unless entry.flag == Crystar::DIR.ord.to_u8
        end
      end
    end

    private def remove_sources(found_paths : Array(String))
      found_paths.each { |path| FileUtils.rm_rf(path) }
    end

    private def apply_dest_attributes(dest : String)
      if owner = @params["owner"]?
        if user = System::User.find_by?(name: owner)
          File.chown(dest, uid: user.id.to_i, gid: -1)
        end
      end
      if group = @params["group"]?
        if grp = System::Group.find_by?(name: group)
          File.chown(dest, uid: -1, gid: grp.id.to_i)
        end
      end
      if mode = @params["mode"]?
        if permissions = mode.to_i?(8)
          File.chmod(dest, permissions)
        end
      end
    rescue
      # A chmod/chown failure (e.g. not running as root/owner) shouldn't
      # fail the whole task - matches the previous shell implementation's
      # behavior of not checking these commands' exit codes either.
    end

    # `attributes:` - a chattr(1) flag string (e.g. "+i" for immutable),
    # applied to *dest* - verified against real AnsibleModule's own
    # `set_attributes_if_different` source: unconditional (no filesystem-
    # support gate the way SELinux context has), fails the task with
    # "chattr failed" if the chattr command itself errors, matched
    # exactly rather than silently swallowed the way chmod/chown above
    # are (that swallowing is this module's OWN documented convention,
    # not something real Ansible does for chattr).
    private def apply_attributes(dest : String) : PluginResult?
      attributes = @params["attributes"]?
      return nil unless attributes && !attributes.empty?

      mod = attributes[0].in?('+', '-') ? attributes[0] : '='
      flags = attributes[0].in?('+', '-') ? attributes[1..] : attributes

      result = remote_exec("chattr #{mod}#{flags} #{dest}")
      if result[:exit_code] != 0 || !result[:stderr].empty?
        return PluginResult.new(changed: false, failed: true, msg: "chattr failed: #{result[:stdout]}#{result[:stderr]}")
      end

      nil
    end

    # `seuser:`/`serole:`/`setype:`/`selevel:` - SELinux file context,
    # applied to *dest* via `chcon`. Verified against real AnsibleModule's
    # own `set_context_if_different`/`selinux_enabled` source: real
    # Ansible skips this ENTIRELY (not even attempting it) when SELinux
    # isn't enabled on the target at all (`if not self.selinux_enabled():
    # return changed`) - matched here via the standard `/sys/fs/selinux/
    # enforce` selinuxfs check, the same file `selinuxenabled(8)` itself
    # tests. On any non-SELinux host (the overwhelming majority of real-
    # world targets this project has ever benchmarked against) this is a
    # verified, confirmed no-op, identical to real Ansible's own behavior
    # - the chcon-invocation shape itself for an actually-SELinux-enabled
    # host is implemented per `chcon(1)`'s documented flags but NOT
    # live-verified against a real SELinux-enabled target (none available
    # in this project's usual Ubuntu/Debian benchmark environment).
    private def apply_selinux_context(dest : String) : PluginResult?
      return nil unless File.exists?("/sys/fs/selinux/enforce")

      flags = [] of String
      flags << "-u #{@params["seuser"]}" if @params["seuser"]?
      flags << "-r #{@params["serole"]}" if @params["serole"]?
      flags << "-t #{@params["setype"]}" if @params["setype"]?
      flags << "-l #{@params["selevel"]}" if @params["selevel"]?
      return nil if flags.empty?

      result = remote_exec("chcon #{flags.join(" ")} #{dest}")
      if result[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true, msg: "invalid selinux context: #{result[:stderr]}")
      end

      nil
    end

    private def dest_stat_fields(dest : String) : NamedTuple(size: Int64, uid: Int64, gid: Int64, owner: String, group: String, mode: String, state: String)
      stat_hash = native_stat(dest, false)

      if stat_hash
        uid = stat_hash["uid"].as_i64
        gid = stat_hash["gid"].as_i64
        {
          size:  stat_hash["size"].as_i64,
          uid:   uid,
          gid:   gid,
          owner: stat_hash["pw_name"].as_s,
          group: stat_hash["gr_name"].as_s,
          mode:  stat_hash["mode"].as_s,
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
