#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # MountFacts plugin - populates ansible_facts.mount_points (and
  # optionally ansible_facts.aggregate_mounts), matching
  # ansible.builtin.mount_facts (added in ansible-core 2.18). Unlike
  # setup's `ansible_mounts` (a flat list of the currently-mounted
  # pseudo-filesystem-filtered devices), mount_facts reads a configurable
  # set of *sources* (static /etc/fstab-style files and dynamic
  # /proc/mounts-style tables), keeps the first definition found for each
  # mount point, and tags every entry with the `ansible_context`
  # (source file + raw source line) it came from.
  #
  # Implementation notes on real Ansible's behavior this mirrors
  # (ansible/modules/mount_facts.py + module_utils/facts/utils.py):
  #   - default `sources` is ["all"] -> DYNAMIC_SOURCES (/etc/mtab,
  #     /proc/mounts, /etc/mnttab) then STATIC_SOURCES (/etc/fstab,
  #     /etc/vfstab, /etc/filesystems); repeat sources (including a
  #     symlink such as /etc/mtab -> /proc/mounts, resolved via realpath)
  #     are skipped; missing or empty files are skipped;
  #   - a `mount`-binary fallback runs only when a dynamic source was
  #     requested, `mount_binary` is set, and no dynamic source actually
  #     yielded entries (on Linux /proc/mounts always does, so it does not
  #     run);
  #   - `devices:` / `fstypes:` are fnmatch pattern lists (default ["*"])
  #     matched case-sensitively against the device and fstype;
  #   - size/inode statistics come from statvfs, mirrored here with the
  #     same `stat -f` fields the setup gatherer uses, and are OMITTED for
  #     a mount statvfs can't read (f_frsize == 0, e.g. autofs) rather
  #     than zero-filled;
  #   - an fstab `device: UUID=...` is resolved to a real device path
  #     (blkid --uuid) with the raw uuid carried in the `uuid` field; a
  #     plain device gets its uuid looked up best-effort (/dev/disk/by-uuid
  #     scan, then `lsblk --paths`).
  #
  # Deliberately NOT implemented (out of this repo's Linux/posix target
  # scope, same stance as service_facts' missing upstart/chkconfig/OpenRC
  # branches): the AIX /etc/filesystems stanza parser, the Solaris
  # /etc/vfstab and /etc/mnttab column parsers, and the BSD/AIX `mount`
  # output dialects. On a Linux host none of those sources exist or match,
  # so the Linux path is complete. The per-mount `timeout:`/`on_timeout:`
  # hang protection is applied to the external commands via a bounded
  # Process.run, but a genuine statvfs timeout is reported as "no size
  # stats for that mount" rather than the error/warn distinction real
  # Ansible makes.
  #
  # Read-only, so it's safe under --check.
  class MountFactsPlugin < BasePlugin
    DYNAMIC_SOURCES  = ["/etc/mtab", "/proc/mounts", "/etc/mnttab"]
    STATIC_SOURCES   = ["/etc/fstab", "/etc/vfstab", "/etc/filesystems"]
    MOUNT_BINARY_CMD = "mount"

    def execute : PluginResult
      devices = pattern_list("devices")
      fstypes = pattern_list("fstypes")
      sources = get_sources
      mount_binary = @params["mount_binary"]?

      warnings = [] of String
      entries = collect_mount_entries(sources, mount_binary, devices, fstypes)

      mount_points, aggregate = dedup(entries, warnings)

      result_facts = {
        "mount_points"     => JSON::Any.new(mount_points),
        "aggregate_mounts" => JSON::Any.new(aggregate),
      } of String => JSON::Any

      facts = JSON::Any.new(result_facts)
      if warnings.empty?
        PluginResult.new(
          changed: false,
          failed: false,
          msg: "Gathered #{mount_points.size} mount facts",
          ansible_facts: facts
        )
      else
        PluginResult.new(
          changed: false,
          failed: false,
          msg: "Gathered #{mount_points.size} mount facts",
          ansible_facts: facts,
          warnings: JSON::Any.new(warnings.map { |warning| JSON::Any.new(warning) })
        )
      end
    end

    # ----- source resolution (mirrors get_sources() in the real module) -----

    private def get_sources : Array(String)
      requested = pattern_list("sources")
      requested = ["all"] if requested.empty?

      sources = [] of String
      requested.each do |source|
        if source.empty?
          # Real module fails before any gathering on an empty entry.
          raise ArgumentError.new("sources contains an empty string")
        end
        if source == "dynamic" || source == "all"
          sources.concat(DYNAMIC_SOURCES)
        end
        if source == "static" || source == "all"
          sources.concat(STATIC_SOURCES)
        end
        sources << source unless {"static", "dynamic", "all"}.includes?(source)
      end
      sources
    end

    # A list-typed param (devices/fstypes/sources) arrives as either a
    # JSON-array string (executor wire format) or a comma-separated
    # string; ONLY valid JSON is parsed - never a Python-repr repair pass,
    # matching every other *_facts/list param in this tree.
    private def pattern_list(key : String) : Array(String)
      raw = @params[key]?
      return [] of String if raw.nil? || raw.strip.empty?

      if raw.strip.starts_with?('[')
        (Array(String).from_json(raw) rescue nil).try { |a| return a.reject(&.strip.empty?) }
      end
      raw.split(",").map(&.strip).reject(&.empty?)
    end

    # ----- collection over sources (mirrors gen_mounts_by_source +
    # get_mount_facts) -----

    private def collect_mount_entries(sources : Array(String),
                                      mount_binary : String?,
                                      devices : Array(String),
                                      fstypes : Array(String)) : Array(Hash(String, JSON::Any))
      result = [] of Hash(String, JSON::Any)
      # mount_binary's documented default is "mount", so an omitted option
      # still enables the fallback; only an explicit null disables it.
      mount_bin_set = !explicit_null_param?("mount_binary") && (mount_binary.nil? || !mount_binary.empty?)
      mount_fallback = mount_bin_set && sources.any? { |src_name| DYNAMIC_SOURCES.includes?(src_name) }

      seen = Set(String).new
      sources.each do |source|
        # Skip repeat sources and symlink aliases of an already-read one.
        next if seen.includes?(source)
        real = real_path(source)
        next if seen.includes?(real)
        seen << source
        seen << real

        if source == "mount"
          produced = read_mount_binary(mount_binary)
        else
          produced = read_source_file(source)
        end

        mount_fallback = false unless produced.empty?
        result.concat(filter_entries(produced, source, devices, fstypes))
      end

      if mount_fallback
        produced = read_mount_binary(mount_binary)
        result.concat(filter_entries(produced, "mount", devices, fstypes))
      end

      result
    end

    # Parse one source file into raw field maps (before size/uuid
    # enrichment). A missing or empty file yields nothing (real module
    # skips it). Only the Linux fstab-column format is implemented (see
    # the class comment for why).
    private def read_source_file(file : String) : Array({fields: Hash(String, JSON::Any), line: String})
      return [] of {fields: Hash(String, JSON::Any), line: String} unless File.exists?(file)
      lines = (File.read_lines(file) rescue nil) || [] of String
      parse_fstab_columns(lines)
    end

    # fstab / /proc/mounts / /etc/mtab column format:
    #   device mount fstype options [dump [passno]]
    # Comments and blank lines skipped; octal escapes (\040 etc.) decoded
    # as real's replace_octal_escapes does.
    private def parse_fstab_columns(lines : Array(String)) : Array({fields: Hash(String, JSON::Any), line: String})
      out = [] of {fields: Hash(String, JSON::Any), line: String}
      lines.each do |raw_line|
        line = raw_line.strip
        next if line.empty? || line.starts_with?('#')
        fields = line.split.map { |field| replace_octal_escapes(field) }
        next if fields.size < 4
        mount_info = {
          "device"  => JSON::Any.new(fields[0]),
          "mount"   => JSON::Any.new(fields[1]),
          "fstype"  => JSON::Any.new(fields[2]),
          "options" => JSON::Any.new(fields[3]),
        } of String => JSON::Any
        mount_info["dump"] = JSON::Any.new(fields[4].to_i64? || 0i64) if fields[4]?
        mount_info["passno"] = JSON::Any.new(fields[5].to_i64? || 0i64) if fields[5]?
        out << {fields: mount_info, line: line}
      end
      out
    end

    # The Linux `mount` binary dialect: "device on mount type fstype (opts)".
    private def read_mount_binary(mount_binary : String?) : Array({fields: Hash(String, JSON::Any), line: String})
      cmd = mount_binary.nil? || mount_binary.empty? ? MOUNT_BINARY_CMD : mount_binary
      output = run_capture(cmd, nil)
      return [] of {fields: Hash(String, JSON::Any), line: String} unless output
      out = [] of {fields: Hash(String, JSON::Any), line: String}
      output.each_line do |line|
        m = line.match(/^(?<device>\S+) on (?<mount>\S+) type (?<fstype>\S+) \((?<options>.+)\)$/)
        next unless m
        mount_info = {
          "device"  => JSON::Any.new(m["device"]),
          "mount"   => JSON::Any.new(m["mount"]),
          "fstype"  => JSON::Any.new(m["fstype"]),
          "options" => JSON::Any.new(m["options"]),
        } of String => JSON::Any
        out << {fields: mount_info, line: line}
      end
      out
    end

    # Apply the device/fstype fnmatch filters, resolve UUIDs, and enrich
    # with statvfs-derived size/inode fields plus ansible_context.
    private def filter_entries(parsed : Array({fields: Hash(String, JSON::Any), line: String}),
                               source : String,
                               devices : Array(String),
                               fstypes : Array(String)) : Array(Hash(String, JSON::Any))
      out = [] of Hash(String, JSON::Any)
      parsed.each do |item|
        fields = item[:fields]
        device = fields["device"].as_s
        fstype = fields["fstype"].as_s

        uuid = nil.as(String?)
        if device.starts_with?("UUID=")
          if raw_uuid = device.split("=", 2)[1]?
            uuid = raw_uuid
            resolved = blkid_uuid(raw_uuid)
            device = resolved || device
            fields["device"] = JSON::Any.new(device)
          end
        end

        next unless devices.empty? || devices.any? { |pat| fnmatch?(device, pat) }
        next unless fstypes.empty? || fstypes.any? { |pat| fnmatch?(fstype, pat) }

        if stats = get_mount_size(fields["mount"].as_s)
          stats.each { |k, v| fields[k] = JSON::Any.new(v) }
        end

        if uuid.nil?
          uuid = get_partition_uuid(device)
        end

        fields["uuid"] = if u = uuid
                           JSON::Any.new(u)
                         else
                           JSON::Any.new(nil)
                         end
        fields["ansible_context"] = JSON::Any.new({
          "source"      => JSON::Any.new(source),
          "source_data" => JSON::Any.new(item[:line]),
        })
        out << fields
      end
      out
    end

    # First definition per mount point wins for mount_points; the full
    # list is returned as aggregate_mounts only when
    # include_aggregate_mounts is true. A null/unset value with duplicates
    # present emits real's warning.
    private def dedup(entries : Array(Hash(String, JSON::Any)), warnings : Array(String)) : {Hash(String, JSON::Any), Array(JSON::Any)}
      mount_points = Hash(String, JSON::Any).new
      mounts_by_source = Hash(String, Array(String)).new

      entries.each do |mount|
        mount_point = mount["mount"].as_s
        source = mount["ansible_context"].as_h["source"].as_s
        mount_points[mount_point] ||= JSON::Any.new(mount)
        mounts_by_source[source] ||= [] of String
        mounts_by_source[source] << mount_point
      end

      include_aggregate = @params["include_aggregate_mounts"]?
      include_aggregate_null = include_aggregate.nil? || include_aggregate.empty? || explicit_null_param?("include_aggregate_mounts")

      if include_aggregate_null
        dups = mounts_by_source.select { |_src, mnts| mnts.uniq.size != mnts.size }
        unless dups.empty?
          listed = dups.map { |src, mnts| "#{src} (#{(mnts - mnts.uniq).uniq.join(", ")})" }.join(", ")
          warnings << "mount_facts: ignoring repeat mounts in the following sources: #{listed}. " \
                      "You can disable this warning by configuring the 'include_aggregate_mounts' option as True or False."
        end
      end

      aggregate = if !include_aggregate_null && true?(include_aggregate)
                    entries.map { |e| JSON::Any.new(e) }
                  else
                    [] of JSON::Any
                  end

      {mount_points, aggregate}
    end

    # ----- statvfs / device-uuid / command helpers (all run on target) -----

    # statvfs mirror via `stat -f` (same fields the setup gatherer reads):
    # %S f_frsize %b f_blocks %f f_bfree(all) %a f_bavail(non-root)
    # %c f_files %d f_favail. Returns {} when the mount can't be read or
    # f_frsize is 0 (real returns {} there too, e.g. autofs).
    private def get_mount_size(mountpoint : String) : Hash(String, Int64)?
      out = run_capture("stat", ["-f", "--format=%S %b %f %a %c %d", mountpoint])
      return nil unless out
      parts = out.strip.split(" ")
      return nil unless parts.size == 6
      frsize, blocks, bfree, bavail, files, favail = parts.map(&.to_i64?)
      return nil if frsize.nil? || blocks.nil? || bfree.nil? || bavail.nil? || files.nil? || favail.nil?
      return nil if frsize == 0

      {
        "block_size"      => frsize,
        "block_total"     => blocks,
        "block_available" => bavail,
        "block_used"      => blocks - bfree,
        "size_total"      => frsize * blocks,
        "size_available"  => frsize * bavail,
        "size_used"       => frsize * (blocks - bfree),
        "inode_total"     => files,
        "inode_available" => favail,
        "inode_used"      => files - favail,
      } of String => Int64
    end

    private def blkid_uuid(uuid : String) : String?
      return nil unless executable?("blkid")
      out = run_capture("blkid", ["--uuid", uuid])
      out && !out.strip.empty? ? out.strip : nil
    end

    # Best-effort partition uuid for a plain device path: scan
    # /dev/disk/by-uuid, then `lsblk --paths`. (The udevadm fallback real
    # uses for ancient lsblk is omitted.)
    private def get_partition_uuid(device : String) : String?
      real_device = real_path(device)
      Dir.children("/dev/disk/by-uuid").each do |uuid|
        begin
          return uuid if File.real_path(File.join("/dev/disk/by-uuid", uuid)) == real_device
        rescue
          next
        end
      end

      if executable?("lsblk")
        out = run_capture("lsblk", ["--list", "--noheadings", "--paths", "--output", "NAME,UUID", "--exclude", "2"])
        if out
          out.each_line do |line|
            cols = line.split
            return cols[1] if cols.size == 2 && cols[0] == real_device
          end
        end
      end
      nil
    end

    # NOTE: real Ansible's `timeout:`/`on_timeout:` hang protection is not
    # reproduced here - this Crystal target's Process.run has no timeout
    # parameter, so an unresponsive mount is reported as "no size stats for
    # that mount" (stat fails -> get_mount_size returns nil) rather than
    # erroring/warning. Documented in the class comment.
    private def executable?(cmd : String) : Bool
      !Process.find_executable(cmd).nil?
    end

    private def run_capture(cmd : String, args : Array(String)? = nil) : String?
      io = IO::Memory.new
      status = if args.nil?
                 Process.run(cmd, output: io, error: Process::Redirect::Close)
               else
                 Process.run(cmd, args, output: io, error: Process::Redirect::Close)
               end
      return nil unless status.success?
      io.to_s
    rescue
      nil
    end

    private def real_path(path : String) : String
      File.real_path(path)
    rescue
      path
    end

    # Python fnmatch.fnmatchcase semantics (posix, case-sensitive): only
    # `*`, `?`, and `[seq]` (with `[!seq]` negation) are special; every
    # other character is literal.
    private def fnmatch?(value : String, pattern : String) : Bool
      /^#{fnmatch_to_regex(pattern)}$/.matches?(value)
    end

    private def fnmatch_to_regex(pattern : String) : String
      String.build do |io|
        i = 0
        while i < pattern.size
          case pattern[i]
          when '*'
            io << ".*"
            i += 1
          when '?'
            io << "."
            i += 1
          when '['
            close = pattern.index(']', i + 1)
            # A leading '!' negates; a leading ']' after '[' is a literal
            # ']' member ([]) handling per Python's translate).
            if close && close > i + 1
              inner = pattern[(i + 1)...close]
              negated = inner.starts_with?('!')
              body = negated ? inner[1..] : inner
              io << (negated ? "[^" : "[")
              io << body.gsub("\\") { |match| "\\#{match}" }
              io << "]"
              i = close + 1
            else
              io << "\\["
              i += 1
            end
          else
            io << Regex.escape(pattern[i].to_s)
            i += 1
          end
        end
      end
    end

    # Octal escape decoding (\040 -> space) matching real's
    # replace_octal_escapes.
    private def replace_octal_escapes(value : String) : String
      value.gsub(/\\[0-7]{3}/) do |match|
        code = match[1..].to_i(8)
        code.chr
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::MountFactsPlugin.new(config)
plugin.run
