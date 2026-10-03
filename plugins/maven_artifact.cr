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

    # The interpreter real's module would run under (the discovered one):
    # the first existing python3/python, resolved to its realpath the way
    # interpreter discovery reports it (/usr/bin/python3.13-style).
    private def target_python : String?
      %w[python3 python].each do |interpreter|
        next unless Process.find_executable(interpreter)
        io = IO::Memory.new
        status = Process.run(interpreter, {"-c", "import os, sys; print(os.path.realpath(sys.executable))"},
          output: io, error: Process::Redirect::Close)
        return io.to_s.strip if status.success?
      end
      nil
    end

    private def python_lib_available?(python : String, module_name : String) : Bool
      io = IO::Memory.new
      Process.run(python, {"-c", "import #{module_name}"}, output: io, error: Process::Redirect::Close).success?
    end

    # ansible.module_utils.basic.missing_required_lib's exact boilerplate.
    private def missing_required_lib_msg(library : String, python : String) : String
      "Failed to import the required Python library (#{library}) on #{System.hostname}'s Python #{python}. " \
      "Please read the module documentation and install it in the appropriate location. " \
      "If the required library is installed, but Ansible is using the wrong Python interpreter, " \
      "please consult the documentation on ansible_python_interpreter"
    end

    def execute : PluginResult
      # Real maven_artifact passes no supports_check_mode=True to its
      # AnsibleModule, so real Ansible's action plugin never runs the
      # module under check mode at all - the task skips with "remote
      # module (...) does not support check mode" (round 994002
      # kop_misc2: registered skipped, msg, failed, changed; the recap
      # shows skipping where this plugin used to run the download and
      # count changed). Same shape as tempfile/wait_for's identical
      # gate.
      if true?(@params["_ansible_check_mode"]?)
        invoked = @params["_module_name"]? || "community.general.maven_artifact"
        return PluginResult.new(changed: false, failed: false,
          msg: "remote module (#{invoked}) does not support check mode", skipped: true,
          omit_changed: true, key_order: ["skipped", "msg"])
      end

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

      classifier = @params["classifier"]? || ""
      extension = @params["extension"]? || "jar"
      repository_url = @params["repository_url"]?.presence || DEFAULT_REPOSITORY_URL
      username = @params["username"]?
      password = @params["password"]?
      validate_certs = @params["validate_certs"]? ? true?(@params["validate_certs"]?, default: true) : true
      keep_name = true?(@params["keep_name"]?)
      verify_checksum = @params["verify_checksum"]? || "download"
      return PluginResult.new(changed: false, failed: true,
        msg: "value of verify_checksum must be one of: never, download, change, always, got: #{verify_checksum}") unless ["never", "download", "change", "always"].includes?(verify_checksum)
      checksum_alg = @params["checksum_alg"]? || "md5"
      return PluginResult.new(changed: false, failed: true,
        msg: "value of checksum_alg must be one of: md5, sha1, got: #{checksum_alg}") unless ["md5", "sha1"].includes?(checksum_alg)

      # Real's import-time dependency checks run right after the
      # argument_spec validation and before anything else in main()
      # (live-verified vs 2.19.11 in the no-network container: the lxml
      # import failure beats version_by_spec spec parsing, the
      # repository URL handling and every download attempt). The
      # missing_required_lib boilerplate carries the hostname and the
      # interpreter real would run under (its sys.executable).
      if python = target_python
        unless python_lib_available?(python, "lxml")
          return PluginResult.new(changed: false, failed: true, msg: missing_required_lib_msg("lxml", python))
        end
        if version_by_spec && !python_lib_available?(python, "semantic_version")
          return PluginResult.new(changed: false, failed: true, msg: missing_required_lib_msg("semantic_version", python))
        end
      end

      if repository_url.starts_with?("s3://")
        return PluginResult.new(changed: false, failed: true,
          msg: "s3:// repository URLs are not supported by this implementation")
      end
      local = repository_url.starts_with?("file://")

      # Real's Artifact() constructor ValueError (version_by_spec specs it
      # cannot parse) runs AFTER the import-time library checks and the
      # s3/boto gate.
      return PluginResult.new(changed: false, failed: true,
        msg: "The spec version #{version_by_spec} is not supported! ") if version_by_spec

      if !version && !version_by_spec
        version = "latest"
      end

      base = repository_url.chomp("/")

      # MavenDownloader uses a different metadata filename for local
      # (file://) repositories: maven-metadata-local.xml.
      metadata_file_name = local ? "maven-metadata-local.xml" : "maven-metadata.xml"

      # version resolution (find_uri_for_artifact)
      if version == "latest"
        metadata = fetch_metadata(base, "#{base}/#{PluginHelpers::MavenArtifactCommand.artifact_path(group_id.not_nil!, artifact_id.not_nil!, nil)}/#{metadata_file_name}", local)
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
        metadata_path = "#{base}/#{PluginHelpers::MavenArtifactCommand.artifact_path(group_id.not_nil!, artifact_id.not_nil!, version_str)}/#{metadata_file_name}"
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
      artifact_file = version_part == version_str && !is_snapshot ? "#{artifact_id}-#{version_str}#{classifier.empty? ? "" : "-#{classifier}"}.#{extension}" : "#{artifact_id}-#{version_part}#{classifier.empty? ? "" : "-#{classifier}"}.#{extension}"
      artifact_url = "#{base}/#{repo_relative}/#{artifact_file}"

      # dest is a directory -> generated filename under it; dest is a
      # file -> used as-is. A dest ending in the path separator is
      # created up front (real main()'s os.makedirs branch), and an
      # EXISTING directory counts as a directory too (real main()'s
      # os.path.isdir(b_dest) branch fires on any existing directory,
      # not just trailing-slash spellings - a pre-created dest
      # directory without the trailing slash used to be treated as a
      # file path, and since File.exists? is true for a directory the
      # module then reported "artifact already present" without
      # downloading anything).
      dest_str = dest.not_nil!
      Dir.mkdir_p(dest_str) if dest_str.ends_with?("/") && !Dir.exists?(dest_str)
      final_dest = (dest_str.ends_with?("/") || Dir.exists?(dest_str)) ? PluginHelpers::MavenArtifactCommand.dest_filename(dest_str, artifact_id.not_nil!, version_part, classifier, extension, keep_name) : dest_str

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

      return artifact_result(final_dest, false, group_id, artifact_id,
        version_str, classifier, extension, repository_url) if prev_state == "present"

      download_result = download(artifact_url, final_dest, username, password, validate_certs, local, verify_download, checksum_alg,
        "Failed to download artifact #{artifact_display(group_id.not_nil!, artifact_id.not_nil!, version_str, classifier, extension)}")
      return download_result if download_result.is_a?(PluginResult)

      artifact_result(final_dest, true, group_id, artifact_id,
        version_str, classifier, extension, repository_url)
    end

    # Real Artifact.__str__: g:a:version, with the extension spliced in
    # when it is not jar and the classifier after it when given - the
    # coordinate string the downloader's failure message echoes.
    private def artifact_display(group_id : String, artifact_id : String, version : String,
                                 classifier : String, extension : String) : String
      if !classifier.empty?
        "#{group_id}:#{artifact_id}:#{extension}:#{classifier}:#{version}"
      elsif extension != "jar"
        "#{group_id}:#{artifact_id}:#{extension}:#{version}"
      else
        "#{group_id}:#{artifact_id}:#{version}"
      end
    end

    # Real main()'s two exit shapes: the changed download echoes the
    # artifact coordinates before `changed`, the no-op exits with
    # state/dest/changed only - then _return_formatted's add_path_info
    # OVERWRITES `state` with the dest file's kind and appends the stat
    # block (uid, gid, owner, group, mode, size) when the path exists
    # (round 994002 kop_misc2: download registers state, dest,
    # group_id, artifact_id, version, classifier, extension,
    # repository_url, changed, uid, gid, owner, group, mode, size,
    # failed; the no-op registers state, dest, changed, uid, ... -
    # state "file" even when state=absent was requested, because real
    # never deletes the file).
    private def artifact_result(final_dest : String, changed : Bool, group_id : String?,
                                artifact_id : String?, version : String, classifier : String,
                                extension : String, repository_url : String) : PluginResult
      order = if changed
                ["state", "dest", "group_id", "artifact_id", "version", "classifier",
                 "extension", "repository_url", "changed", "uid", "gid", "owner", "group", "mode", "size"]
              else
                ["state", "dest", "changed", "uid", "gid", "owner", "group", "mode", "size"]
              end
      result = PluginResult.new(changed: changed, failed: false, key_order: order)
      if changed
        result.extra["group_id"] = JSON::Any.new(group_id.not_nil!)
        result.extra["artifact_id"] = JSON::Any.new(artifact_id.not_nil!)
        result.extra["version"] = JSON::Any.new(version)
        result.extra["classifier"] = JSON::Any.new(classifier)
        result.extra["extension"] = JSON::Any.new(extension)
        result.extra["repository_url"] = JSON::Any.new(repository_url)
      end
      result.extra["dest"] = JSON::Any.new(final_dest)
      if stat = path_stat(final_dest)
        result.extra["uid"] = JSON::Any.new(stat[:uid])
        result.extra["gid"] = JSON::Any.new(stat[:gid])
        result.extra["owner"] = JSON::Any.new(stat[:owner])
        result.extra["group"] = JSON::Any.new(stat[:group])
        result.extra["mode"] = JSON::Any.new(stat[:mode])
        result.extra["size"] = JSON::Any.new(stat[:size])
        result.extra["state"] = JSON::Any.new(stat[:kind])
      else
        result.extra["state"] = JSON::Any.new(@params["state"]? || "present")
      end
      result
    end

    # add_path_info's stat block, same '0%03o' octal-string rendering
    # known_hosts.cr uses: uid/gid ints, owner/group names, size int,
    # and the path kind (link/directory/hard/file) that overwrites the
    # module's own state value. nil when the path is gone.
    private def path_stat(path : String) : NamedTuple(uid: Int64, gid: Int64, owner: String, group: String, mode: String, size: Int64, kind: String)?
      io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("stat", {"-c", "%u|%g|%U|%G|%s|%a|%h|%F", "--", path}, output: io, error: err)
      return nil unless status.success?

      parts = io.to_s.strip.split("|")
      return nil unless parts.size == 8

      uid = parts[0].to_i64?
      gid = parts[1].to_i64?
      size = parts[4].to_i64?
      nlink = parts[6].to_i64?
      return nil unless uid && gid && size && nlink

      kind = if parts[7].starts_with?("symbolic link")
               "link"
             elsif parts[7].starts_with?("directory")
               "directory"
             elsif nlink > 1
               "hard"
             else
               "file"
             end

      {
        uid:   uid,
        gid:   gid,
        owner: parts[2],
        group: parts[3],
        mode:  "0" + parts[5].rjust(3, '0'),
        size:  size,
        kind:  kind,
      }
    end

    private def fetch_metadata(base : String, url : String, local : Bool) : (String | PluginResult)
      if local
        path = URI.parse(url).path
        return File.exists?(path) ? File.read(path) : PluginResult.new(changed: false, failed: true,
          msg: "Failed to retrieve the maven metadata file: #{path} because can not find file: #{url}")
      end
      # Real find_latest_version_available/find_uri_for_artifact's
      # failmsg echoes the repo-relative metadata path, not the URL.
      get(url, "Failed to retrieve the maven metadata file: #{url.lchop(base)}", nil, nil, true)
    end

    # Real MavenDownloader._request's failure: ValueError(failmsg +
    # " because of " + info['msg'] + "for URL " + url_to_use) - note
    # real's own missing space before "for URL" (round 994002
    # kop_misc2), and fetch_url's "HTTP Error <code>: <reason>" msg.
    private def get(url : String, failmsg : String, username : String?, password : String?,
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
        reason = response.status.try(&.description) || ""
        required ? PluginResult.new(changed: false, failed: true,
          msg: "#{failmsg} because of HTTP Error #{response.status_code}: #{reason}for URL #{url}") : ""
      ensure
        client.try(&.close)
      end
    end

    private def download(url : String, dest : String, username : String?, password : String?,
                         validate_certs : Bool, local : Bool, verify_download : Bool,
                         checksum_alg : String, failmsg : String) : PluginResult?
      tmp = File.tempname("maven-artifact")
      begin
        if local
          path = URI.parse(url).path
          return PluginResult.new(changed: false, failed: true,
            msg: "Cannot retrieve the artifact to destination: Can not find local file: #{path}") unless File.exists?(path)
          FileUtils.cp(path, tmp)
          # Real's local branch uses shutil.copy2 - the SOURCE file's
          # mode travels to dest through the tempfile.
          File.chmod(tmp, File.info(path).permissions)
        else
          content = get(url, failmsg, username, password, true, validate_certs)
          return content if content.is_a?(PluginResult)
          File.write(tmp, content.as(String))
          # Real downloads into a tempfile.mkstemp file (mode 0600) and
          # shutil.move preserves it - the registered stat block's mode
          # for an HTTP-downloaded artifact is 0600 (round 994002).
          File.chmod(tmp, 0o600)
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
      remote = get("#{artifact_url}.#{checksum_alg}", "Failed to fetch checksum #{artifact_url}.#{checksum_alg}", username, password, false, validate_certs)
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
