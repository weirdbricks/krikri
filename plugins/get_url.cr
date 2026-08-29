#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/http_download"

module CrystalPlay
  # get_url plugin (ansible.builtin.get_url) - downloads a URL to a file.
  #
  # Uses Crystal stdlib HTTP::Client natively rather than shelling to
  # curl/wget. Unlike a plain "local vs remote" split elsewhere in this
  # codebase, no remote_exec branch is needed here at all: PluginManager
  # already uploads and executes this plugin's own compiled binary
  # directly on the target host for non-local connections (see
  # BasePlugin#native_stat's own comment on the same point), so an
  # HTTP::Client call made from inside this process already runs on
  # whichever host - local or remote - the task is targeting.
  class GetUrlPlugin < BasePlugin
    MAX_REDIRECTS = 10

    def execute : PluginResult
      url = @params["url"]?
      dest = @params["dest"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: url") unless url
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: dest") unless dest

      dest = expand_tilde(dest)
      dest = File.directory?(dest) ? File.join(dest, File.basename(URI.parse(url).path)) : dest

      checksum = nil
      if checksum_param = @params["checksum"]?
        begin
          checksum = parse_checksum(checksum_param, url)
        rescue ex
          return PluginResult.new(changed: false, failed: true, msg: "failed to resolve checksum: #{ex.message}")
        end
      end

      force = true?(@params["force"]?, default: false)

      if File.exists?(dest) && !force
        if skip_result = check_existing_dest(dest, checksum)
          return skip_result
        end
        # Checksum given but doesn't match: fall through and re-download,
        # regardless of force - the checksum is its own freshness check,
        # matching real Ansible's get_url behavior.
      end

      if true?(@params["check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "would download #{url} to #{dest} (check mode)", dest: dest)
      end

      download_to_dest(url, dest, checksum)
    end

    # Returns a PluginResult if the download can be skipped (dest already
    # present and, when a checksum was given, matching), nil to signal
    # "proceed with download".
    private def check_existing_dest(dest : String, checksum : {String, String}?) : PluginResult?
      mode, owner, group = @params["mode"]?, @params["owner"]?, @params["group"]?
      check_mode = true?(@params["check_mode"]?)

      if checksum
        algorithm, expected = checksum
        actual = native_checksum(dest, algorithm)
        return nil unless actual == expected

        apply_owner_group_mode(dest, owner, group, mode) unless check_mode
        PluginResult.new(changed: false, failed: false, msg: "file already exists and checksum matches", dest: dest, checksum_src: nil, checksum_dest: nil)
      else
        apply_owner_group_mode(dest, owner, group, mode) unless check_mode
        PluginResult.new(changed: false, failed: false, msg: "file already exists (use force=yes to overwrite)", dest: dest)
      end
    end

    private def download_to_dest(url : String, dest : String, checksum : {String, String}?) : PluginResult
      tmp_path = "#{dest}.#{Process.pid}.tmp"

      begin
        download(url, tmp_path)
      rescue ex
        File.delete(tmp_path) if File.exists?(tmp_path)
        return PluginResult.new(changed: false, failed: true, msg: "failed to download #{url}: #{ex.message}")
      end

      if checksum
        algorithm, expected = checksum
        actual = native_checksum(tmp_path, algorithm)
        unless actual == expected
          File.delete(tmp_path) if File.exists?(tmp_path)
          return PluginResult.new(changed: false, failed: true, msg: "checksum mismatch: expected #{expected}, got #{actual}")
        end
      end

      # Real bug found benchmarking geerlingguy.jenkins: its own "Add
      # Jenkins apt repository key." task uses `force: true` - real
      # Ansible's own get_url module treats force: true as "always
      # re-download, bypassing freshness checks" (Last-Modified/ETag),
      # NOT "always report changed": it still compares the freshly
      # downloaded content against whatever's already at dest: before
      # deciding changed, so a `force: true` task whose URL's content
      # hasn't actually changed still converges to changed: false on a
      # rerun. Unconditionally reporting changed: true here meant EVERY
      # force: true get_url task (a common idiom for "always fetch the
      # latest, but converge if identical" URLs like signing keys)
      # reported changed forever, with no way to ever settle.
      unchanged = File.exists?(dest) && native_checksum(dest, "sha256") == native_checksum(tmp_path, "sha256")

      if unchanged
        File.delete(tmp_path)
        apply_owner_group_mode(dest, @params["owner"]?, @params["group"]?, @params["mode"]?)
        return PluginResult.new(changed: false, failed: false, msg: "file already exists and content matches", dest: dest)
      end

      if true?(@params["backup"]?) && File.exists?(dest)
        File.copy(dest, "#{dest}.#{Time.utc.to_s("%Y-%m-%d@%H:%M:%S")}~")
      end

      dest_dir = File.dirname(dest)
      Dir.mkdir_p(dest_dir) unless Dir.exists?(dest_dir)
      File.rename(tmp_path, dest)

      apply_owner_group_mode(dest, @params["owner"]?, @params["group"]?, @params["mode"]?)

      PluginResult.new(changed: true, failed: false, msg: "OK", dest: dest, checksum_src: native_checksum(dest, "sha1"), checksum_dest: nil)
    end

    # checksum: "<algo>:<value>" where value is either a literal hex hash or,
    # per real Ansible's documented get_url behavior, a URL pointing to a
    # sha*sums-format file (one "<hash>  <filename>" line per file) - in
    # which case the hash for `url`'s own basename is looked up within it.
    private def parse_checksum(checksum_param : String, url : String) : {String, String}
      algorithm, _, value = checksum_param.partition(":")
      algorithm = algorithm.downcase

      if value.starts_with?("http://") || value.starts_with?("https://")
        {algorithm, resolve_checksum_url(value, url)}
      else
        {algorithm, value.downcase}
      end
    end

    private def resolve_checksum_url(checksum_url : String, target_url : String) : String
      tmp_path = "#{Dir.tempdir}/get_url_checksum_#{Process.pid}_#{Random.rand(1_000_000)}.tmp"
      begin
        PluginHelpers::HTTPDownload.download(checksum_url, tmp_path, download_options)

        target_basename = File.basename(URI.parse(target_url).path)
        File.each_line(tmp_path) do |line|
          # sha*sums format: "<hex-hash> [*]<filename>" (the optional "*"
          # marks binary mode, per sha256sum(1)).
          hash, _, filename = line.strip.partition(/\s+/)
          next if hash.empty? || filename.empty?
          filename = filename.lstrip('*')
          return hash.downcase if File.basename(filename) == target_basename
        end

        raise "no checksum entry for #{target_basename} found in #{checksum_url}"
      ensure
        File.delete(tmp_path) if File.exists?(tmp_path)
      end
    end

    private def download(url : String, tmp_path : String) : Nil
      # Delegates to the shared HTTPDownload helper (also used by
      # deb822_repository.cr) so both plugins share one redirect-following,
      # binary-safe download implementation. get_url's own extra knobs
      # (timeout, validate_certs, basic auth, custom headers) map onto the
      # helper's Options.
      PluginHelpers::HTTPDownload.download(url, tmp_path, download_options)
    end

    private def download_options : PluginHelpers::HTTPDownload::Options
      PluginHelpers::HTTPDownload::Options.new(
        max_redirects: MAX_REDIRECTS,
        connect_timeout: timeout_span,
        read_timeout: timeout_span,
        headers: request_headers,
        verify_tls: true?(@params["validate_certs"]?, default: true),
        username: @params["url_username"]?,
        password: @params["url_password"]?,
      )
    end

    private def timeout_span : Time::Span
      (@params["timeout"]? || "10").to_i.seconds
    end

    private def request_headers : HTTP::Headers
      headers = HTTP::Headers.new
      headers["User-Agent"] = @params["http_agent"]? || "ansible-httpget"

      if headers_param = @params["headers"]?
        headers_param.split(",").each do |pair|
          key, _, value = pair.partition(":")
          headers[key.strip] = value.strip unless key.blank?
        end
      end

      headers
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::GetUrlPlugin.new(config)
plugin.run
