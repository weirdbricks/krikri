module Krikri
  module PluginHelpers
    # AptRepositoryLine - pure logic for normalizing an apt_repository
    # `repo:` line and deriving its default sources.list.d filename. No
    # I/O here - the plugin itself does the actual file reads/writes.
    module AptRepositoryLine
      VALID_SOURCE_TYPES = {"deb", "deb-src"}

      # Strips and collapses whitespace, validates the line starts with
      # deb/deb-src - matches real Ansible's own SourcesList#_parse
      # validation before a source line is compared or stored.
      def self.normalize(repo : String) : String?
        chunks = repo.strip.split
        return nil if chunks.empty?
        return nil unless VALID_SOURCE_TYPES.includes?(chunks[0])

        chunks.join(" ")
      end

      # Replicates real Ansible's own `_suggest_filename` exactly
      # (verified by reading apt_repository.py's actual source and
      # cross-checking output against a real Python re-implementation of
      # it, not assumed from docs): strip `[options]` and the
      # `scheme://` prefix, drop the deb/deb-src keyword(s), strip any
      # user:pass@ prefix from the first remaining token, then replace
      # every non-alphanumeric character with a space and join the words
      # with underscores.
      def self.suggested_filename(normalized : String) : String
        line = normalized.gsub(/\[[^\]]+\]/, "")
        line = line.gsub(/\w+:\/\//, "")

        parts = line.split.reject { |part| VALID_SOURCE_TYPES.includes?(part) }
        return "" if parts.empty?

        first = strip_username_password(parts[0])
        cleanup_filename(first)
      end

      def self.strip_username_password(part : String) : String
        part.includes?('@') ? part.split('@', 2).last : part
      end

      # Resolves the actual sources.list.d file path an added repo line
      # lands in, replicating real Ansible's own flow exactly
      # (apt_repository.py: an explicit `filename:` param goes through
      # `_suggest_filename` - which returns it VERBATIM and then
      # unconditionally appends `.list` - followed by `_expand_path`,
      # which passes anything containing '/' through as-is instead of
      # joining sources_dir). So `filename: keydb` ->
      # <sources_list_d>/keydb.list, but a full path like
      # `filename: /etc/apt/sources.list.d/keydb.list` (v0112358.
      # keydb_active_replication) intentionally lands at
      # /etc/apt/sources.list.d/keydb.list.LIST.LIST - i.e.
      # /etc/apt/sources.list.d/keydb.list.list: quirky, but exactly
      # what real Ansible writes, and apt reads any *.list under
      # sources.list.d, so the repo IS live for apt. Found via
      # v0112358.keydb_active_replication, where joining the full-path
      # param under sources_list_d instead produced a nested
      # apt-never-reads path: `apt-get update` then exits 0 with no GPG
      # warning (the repo file is simply invisible to apt), the task
      # still reported changed/success, and the later
      # `apt: name=keydb` failed with "Unable to locate package keydb"
      # where real Ansible's identical sequence installed it.
      def self.target_sources_path(filename_param : String?, filename_source : String, sources_list_d : String) : String
        if filename_param
          candidate = "#{filename_param}.list"
          return candidate if candidate.includes?('/')

          return File.join(sources_list_d, candidate)
        end

        File.join(sources_list_d, "#{suggested_filename(filename_source)}.list")
      end

      def self.cleanup_filename(source : String) : String
        source.gsub(/[^a-zA-Z0-9]/, " ").split.reject(&.empty?).join("_")
      end
    end
  end
end
