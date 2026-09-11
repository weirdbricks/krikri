#!/usr/bin/env crystal

require "json"
require "uri"
require "openssl"
require "base64"
require "http/client"
require "digest/md5"
require "digest/sha1"
require "file_utils"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/maven_artifact_command"

module Krikri
  # maven_artifact plugin - a native port of
  # community.general.maven_artifact: downloads a Maven artifact to
  # dest, resolving "latest" versions and SNAPSHOT timestamps through
  # the repository's maven-metadata.xml, with checksum verification.
  #
  # Follows the real module's control flow:
  #   - repo path is group_id (dots->slashes) / artifact_id
  #     [/version], timestamped snapshot versions keep a SNAPSHOT
  #     directory; the artifact file is
  #     artifact_id[-version][-classifier].extension, joined under
  #     dest when dest is a directory (keep_name keeps the version)
  #   - version=latest (or no version at all) resolves through
  #     /maven-metadata.xml's last <version> entry; SNAPSHOT versions
  #     resolve through snapshotVersions (classifier+extension match,
  #     newest `updated`) or the timestamp/buildNumber fallback
  #   - download -> verify checksum (url + ".md5"/".sha1", first
  #     token, case-insensitive) -> move to dest; per verify_checksum
  #     the checksum gates the download (download/always), the
  #     already-present dest file (change/always), or nothing (never)
  #   - changed only when the file was actually (re)downloaded
  #   - basic auth via username/password; validate_certs=false
  #     disables TLS verification; file:// repositories read locally
  #
  # Deliberately left out: version_by_spec version ranges (requires
  # the semantic_version library's Spec.select - fails with the real
  # module's "not supported" message shape), s3:// repository URLs
  # (boto3-dependent upstream; fails with an explicit message here),
  # custom HTTP headers/unredirected_headers pass-through, and the
  # file-common-args permission management on the downloaded file.
  class MavenArtifactPlugin < BasePlugin
    DEFAULT_REPOSITORY_URL = "https://repo1.maven.org/maven2"

    def execute : PluginResult
      group_id = @params["group_id"]?
      artifact_id = @params["artifact_id"]?
      dest = @params["dest"]?

      return PluginResult.new(changed: false, failed: true,
        msg: "missing required arguments: group_id") unless group_id
      return PluginResult.new(changed: false, failed: true,
        msg: "missing required arguments: artifact_id") unless artifact_id
      return PluginResult.new(changed: false, failed: true,
        msg: "missing required arguments: dest") unless dest

      version = @params["version"]?
      version_by_spec = @params["version_by_spec"]?
      if version && version_by_spec
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: version|version_by_spec")
      end
      return PluginResult.new(changed: false, failed: true,
        msg: "The spec version #{version_by_spec} is not supported! ") if version_by_spec

      classifier = @params["classifier"]? || ""
      extension = @params["extension"]? || "jar"
      repository_url = @params["repository_url"]?.presence || DEFAULT_REPOSITORY_URL
      username = @params["username"]?
      password = @params["password"]?
      validate_certs = @params["validate_certs"]? ? true?(@params["validate_certs"]?, default: true) : true
      keep_name = true?(@params["keep_name"]?)
      verify_checksum = @params["verify_checksum"]? || "download"
      return PluginResult.new(changed: false, failed: true,
        msg: "value of verify_checksum must be one of: never, download, change, always, got #{verify_checksum}") unless ["never", "download", "change", "always"].includes?(verify_checksum)
      checksum_alg = @params["checksum_alg"]? || "md5"
      return PluginResult.new(changed: false, failed: true,
        msg: "value of checksum_alg must be one of: md5, sha1, got #{checksum_alg}") unless ["md5", "sha1"].includes?(checksum_alg)

      if repository_url.starts_with?("s3://")
        return PluginResult.new(changed: false, failed: true,
          msg: "s3:// repository URLs are not supported by this implementation")
      end
      local = repository_url.starts_with?("file://")

      if !version && !version_by_spec
        version = "latest"
      end

      base = repository_url.chomp("/")

      # version resolution (find_uri_for_artifact)
      if version == "latest"
        metadata = fetch_metadata(base, "#{base}/#{PluginHelpers::MavenArtifactCommand.artifact_path(group_id.not_nil!, artifact_id.not_nil!, nil)}/maven-metadata.xml", local)
        return metadata if metadata.is_a?(PluginResult)
        version = PluginHelpers::MavenArtifactCommand.latest_version(metadata.as(String))
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to retrieve the maven metadata file: no versions found") unless version
      end

      version_str = version.not_nil!
      is_snapshot = version_str.ends_with?("SNAPSHOT")

      # resolve the concrete file URL
      version_part = version_str
      if is_snapshot && !local
        metadata_path = "#{base}/#{PluginHelpers::MavenArtifactCommand.artifact_path(group_id.not_nil!, artifact_id.not_nil!, version_str)}/maven-metadata.xml"
        metadata = fetch_metadata(base, metadata_path, local)
        return metadata if metadata.is_a?(PluginResult)
        metadata_xml = metadata.as(String)
        snapshot_value = PluginHelpers::MavenArtifactCommand.snapshot_version(metadata_xml, classifier, extension) ||
                         PluginHelpers::MavenArtifactCommand.snapshot_timestamp_version(metadata_xml, version_str)
        return PluginResult.new(changed: false, failed: true,
          msg: "Expected uniqueversion for snapshot artifact #{group_id}:#{artifact_id}:#{version_str}") unless snapshot_value
        version_part = snapshot_value
      end

      repo_relative = PluginHelpers::MavenArtifactCommand.artifact_path(group_id.not_nil!, artifact_id.not_nil!, version_str)
      artifact_file = version_part == version_str && !is_snapshot ?
        "#{artifact_id}-#{version_str}#{classifier.empty? ? "" : "-#{classifier}"}.#{extension}" :
        "#{artifact_id}-#{version_part}#{classifier.empty? ? "" : "-#{classifier}"}.#{extension}"
      artifact_url = "#{base}/#{repo_relative}/#{artifact_file}"

      # dest is a directory -> generated filename under it; dest is a
      # file -> used as-is
      dest_str = dest.not_nil!
      final_dest = dest_str.ends_with?("/") ?
        PluginHelpers::MavenArtifactCommand.dest_filename(dest_str, artifact_id.not_nil!, version_part, classifier, extension, keep_name) :
        dest_str

      verify_download = ["download", "always"].includes?(verify_checksum)
      verify_change = ["change", "always"].includes?(verify_checksum)

      prev_state = "absent"
      if File.exists?(final_dest) || File.symlink?(final_dest)
        if !verify_change
          prev_state = "present"
        else
          local_checksum = file_checksum(final_dest, checksum_alg)
          remote_checksum = fetch_checksum(artifact_url, checksum_alg, username, password, validate_certs, local)
          if remote_checksum.is_a?(String) && PluginHelpers::MavenArtifactCommand.checksum_matches?(local_checksum, remote_checksum)
            prev_state = "present"
          end
        end
      end

      return PluginResult.new(changed: false, failed: false, msg: "artifact already present",
        dest: final_dest, state: "present") if prev_state == "present"

      download_result = download(artifact_url, final_dest, username, password, validate_certs, local, verify_download, checksum_alg)
      return download_result if download_result.is_a?(PluginResult)

      PluginResult.new(changed: true, failed: false, msg: "Artifact downloaded",
        dest: final_dest, group_id: group_id, artifact_id: artifact_id,
        version: version_str, repository_url: repository_url)
    end

    private def fetch_metadata(base : String, url : String, local : Bool) : (String | PluginResult)
      if local
        path = URI.parse(url).path
        return File.exists?(path) ? File.read(path) : PluginResult.new(changed: false, failed: true,
          msg: "Failed to retrieve the maven metadata file: #{url} because can not find file: #{path}")
      end
      get(url, nil, nil, true)
    end

    private def get(url : String, username : String?, password : String?,
                    required : Bool, validate_certs : Bool = true) : (String | PluginResult)
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      begin
        if uri.scheme == "https" && !validate_certs
          if (tls = client.tls?)
            tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
          end
        end
        headers = HTTP::Headers{"Accept" => "*/*"}
        if username && password
          headers["Authorization"] = "Basic #{Base64.strict_encode("#{username}:#{password}")}"
        end
        response = client.get(uri.path + (uri.query ? "?#{uri.query}" : ""), headers)
        return response.body if response.status_code == 200
        required ? PluginResult.new(changed: false, failed: true,
          msg: "Failed to retrieve #{url} because of #{response.status_code} for URL #{url}") : ""
      ensure
        client.try(&.close)
      end
    end

    private def download(url : String, dest : String, username : String?, password : String?,
                         validate_certs : Bool, local : Bool, verify_download : Bool,
                         checksum_alg : String) : PluginResult?
      tmp = File.tempname("maven-artifact")
      begin
        if local
          path = URI.parse(url).path
          return PluginResult.new(changed: false, failed: true,
            msg: "Cannot retrieve the artifact to destination: Can not find local file: #{path}") unless File.exists?(path)
          FileUtils.cp(path, tmp)
        else
          content = get(url, username, password, true, validate_certs)
          return content if content.is_a?(PluginResult)
          File.write(tmp, content.as(String))
        end

        if verify_download
          local_checksum = file_checksum(tmp, checksum_alg)
          remote_checksum = fetch_checksum(url, checksum_alg, username, password, validate_certs, local)
          if remote_checksum.is_a?(PluginResult)
            return remote_checksum
          end
          unless remote_checksum.as(String) && PluginHelpers::MavenArtifactCommand.checksum_matches?(local_checksum, remote_checksum.as(String))
            return PluginResult.new(changed: false, failed: true,
              msg: "Cannot retrieve the artifact to destination: Checksum does not match: we computed #{local_checksum} but the repository states #{remote_checksum}")
          end
        end

        FileUtils.mv(tmp, dest)
        nil
      ensure
        File.delete(tmp) rescue nil
      end
    end

    private def fetch_checksum(artifact_url : String, checksum_alg : String, username : String?,
                               password : String?, validate_certs : Bool, local : Bool) : (String | PluginResult)
      if local
        path = URI.parse(artifact_url).path
        return File.exists?(path) ? file_checksum(path, checksum_alg) : ""
      end
      remote = get("#{artifact_url}.#{checksum_alg}", username, password, false, validate_certs)
      return remote if remote.is_a?(PluginResult)
      body = remote.as(String)
      return PluginResult.new(changed: false, failed: true,
        msg: "Cannot find #{checksum_alg} checksum from #{artifact_url}") if body.empty?
      body
    end

    private def file_checksum(path : String, alg : String) : String
      File.open(path) do |file|
        alg == "sha1" ? Digest::SHA1.hexdigest(file) : Digest::MD5.hexdigest(file)
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::MavenArtifactPlugin.new(config)
plugin.run
