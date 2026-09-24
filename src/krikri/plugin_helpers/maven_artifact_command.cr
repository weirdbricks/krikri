require "krikri-xml"

module Krikri
  module PluginHelpers
    # MavenArtifactCommand - the pure logic of
    # community.general.maven_artifact, split out of the plugin so the
    # repo-path arithmetic, the generated filenames, the
    # maven-metadata.xml parsing (latest version, snapshot resolution)
    # and the checksum comparison are unit-testable without a Maven
    # repository. The plugin executes the HTTP/file transfers.
    module MavenArtifactCommand
      # Artifact#path: group_id with dots -> slashes, then artifact_id,
      # then the version directory - except timestamped snapshot
      # versions ("1.2.3-20240101.123456-7" or "x-1.2.3-..."), whose
      # directory keeps the "SNAPSHOT" spelling (real module's
      # timestamp_version_match rewrite).
      SNAPSHOT_TIMESTAMP_RE = /^(.*-)?([0-9]{8}\.[0-9]{6}-[0-9]+)$/

      def self.artifact_path(group_id : String, artifact_id : String, version : String?, with_version : Bool = true) : String
        parts = [group_id.gsub(".", "/"), artifact_id]
        if with_version && version && !version.empty?
          if match = SNAPSHOT_TIMESTAMP_RE.match(version)
            prefix = match[1] || ""
            parts << "#{prefix}SNAPSHOT"
          else
            parts << version
          end
        end
        parts.reject(&.empty?).join("/")
      end

      # Artifact#_generate_filename / get_filename: when dest is a
      # directory, the artifact lands under its generated name;
      # keep_name keeps the version part of it.
      def self.generated_filename(artifact_id : String, classifier : String?, extension : String) : String
        classifier && !classifier.empty? ? "#{artifact_id}-#{classifier}.#{extension}" : "#{artifact_id}.#{extension}"
      end

      def self.dest_filename(dest : String, artifact_id : String, version_part : String?, classifier : String?, extension : String, keep_name : Bool) : String
        return dest unless dest.ends_with?("/")
        name = keep_name && version_part ? "#{artifact_id}-#{version_part}" : artifact_id
        name += "-#{classifier}" if classifier && !classifier.empty?
        "#{dest}#{name}.#{extension}"
      end

      # find_latest_version_available: the LAST <version> element under
      # /metadata/versioning/versions.
      private def self.versions_node(doc : KXML::Document) : KXML::Element?
        root = doc.root || return nil
        versioning = root.elements.find { |child| child.local_name == "versioning" } || return nil
        versioning.elements.find { |child| child.local_name == "versions" }
      end

      def self.latest_version(metadata_xml : String) : String?
        doc = KXML.parse(metadata_xml)
        versions_node = versions_node(doc) || return nil
        versions_node.elements.reverse_each.find { |child| child.local_name == "version" }.try(&.text_content)
      end

      # Snapshot resolution for find_uri_for_artifact: prefer the
      # snapshotVersions entry matching classifier+extension, else the
      # timestamp/buildNumber fallback
      # (version.replace("SNAPSHOT", "TIMESTAMP-BUILDNUM")).
      def self.snapshot_version(metadata_xml : String, classifier : String, extension : String) : String?
        doc = KXML.parse(metadata_xml)
        root = doc.root || return nil
        versioning = root.elements.find { |child| child.local_name == "versioning" } || return nil
        snapshot_versions = versioning.elements.find { |child| child.local_name == "snapshotVersions" } || return nil
        candidates = [] of {String, String}
        snapshot_versions.elements.select { |child| child.local_name == "snapshotVersion" }.each do |snapshot_version|
          sv_classifier = snapshot_version.elements.find { |child| child.local_name == "classifier" }.try(&.text_content) || ""
          sv_extension = snapshot_version.elements.find { |child| child.local_name == "extension" }.try(&.text_content) || ""
          next unless sv_classifier == classifier && sv_extension == extension
          value = snapshot_version.elements.find { |child| child.local_name == "value" }.try(&.text_content)
          updated = snapshot_version.elements.find { |child| child.local_name == "updated" }.try(&.text_content) || ""
          candidates << {updated, value} if value
        end
        # updated is yyyymmddHHMMSS, so lexical max == newest
        candidates.max_by { |candidate| candidate[0] }[1]? unless candidates.empty?
      end

      # The timestamp/buildNumber fallback, given the base version
      # string ("1.2.3-SNAPSHOT") and the metadata contents.
      def self.snapshot_timestamp_version(metadata_xml : String, version : String) : String?
        doc = KXML.parse(metadata_xml)
        root = doc.root || return nil
        versioning = root.elements.find { |child| child.local_name == "versioning" } || return nil
        snapshot_node = versioning.elements.find { |child| child.local_name == "snapshot" } || return nil
        timestamp = snapshot_node.elements.find { |child| child.local_name == "timestamp" }.try(&.text_content)
        build_number = snapshot_node.elements.find { |child| child.local_name == "buildNumber" }.try(&.text_content)
        timestamp && build_number ? version.sub("SNAPSHOT", "#{timestamp}-#{build_number}") : nil
      end

      # is_invalid_checksum: the remote checksum file may carry a
      # trailing filename; only the first token compares, case
      # insensitively.
      def self.checksum_matches?(local_checksum : String, remote_checksum : String) : Bool
        remote_first = remote_checksum.split(/\s+/, remove_empty: true).first? || ""
        local_checksum.downcase == remote_first.downcase
      end
    end
  end
end
