module CrystalPlay
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

      def self.cleanup_filename(source : String) : String
        source.gsub(/[^a-zA-Z0-9]/, " ").split.reject(&.empty?).join("_")
      end
    end
  end
end
