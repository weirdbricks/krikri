#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Unarchive plugin - extracts an archive into a directory. Compatible
  # with Ansible's ansible.builtin.unarchive module (verified via
  # `ansible-doc unarchive` - unlike `community.general.archive`, this one
  # does ship with ansible-core, so it's registered under
  # ansible.builtin.* like most other plugins here).
  #
  # Supported parameters:
  # - src: path to the archive (required) - a local (already-on-target)
  #   path in the common case, matching how crystal-ansible's copy:
  #   plugin already handles local-vs-remote; a plain `remote_src` param
  #   is accepted for compatibility but otherwise has no effect. If src:
  #   contains "://" (a URL), it's fetched first regardless of
  #   remote_src:'s own value - real Ansible's own documented behavior
  # - dest: existing directory to extract into (required - crystal-ansible
  #   fails if it doesn't already exist, same as real Ansible: this module
  #   never creates dest itself)
  # - creates: skip extraction if this path already exists (checked
  #   before doing anything else, same idempotency shortcut command:/
  #   shell: already support)
  # - exclude / include: comma-separated member paths/globs, passed
  #   straight through to tar's --exclude / zip's -x and file-list
  #   arguments - real tar/zip's own matching semantics apply (a pattern
  #   with no "/" matches by path component, one with "/" matches the
  #   literal relative path - verified against real ansible-playbook,
  #   which itself just forwards these to the same underlying tools)
  # - keep_newer: don't overwrite an existing file that's newer than the
  #   archive's copy (default false)
  # - list_files: include the archive's member list in the result
  #   (default false)
  # - mode / owner / group: applied to the DESTINATION DIRECTORY itself,
  #   not to each extracted file - verified against real ansible-playbook's
  #   actual return value shape (`mode`/`owner`/`group`/`uid`/`gid`
  #   describe dest, not individual members)
  #
  # Archive type is auto-detected by attempting to read it (`tar tf`, then
  # `unzip -l`), not by file extension - matches real Ansible's own
  # handler-probing approach (`can_handle_archive`), and means GNU tar's
  # own compression auto-detection handles gz/bz2/xz/plain tar uniformly
  # without needing a --format: parameter the way community.general's
  # `archive` plugin does.
  #
  # Idempotency for tar-based archives uses `tar --compare` against dest,
  # the same mechanism real Ansible's TgzArchive#is_unarchived uses. For
  # zip, a simpler per-member checksum comparison is used instead of
  # replicating real Ansible's much more involved zipinfo/permission-based
  # check - an approximation, documented as such.
  #
  # - extra_opts: raw flags passed straight through to `tar` (e.g.
  #   `--strip-components=1`) - NOT forwarded to `unzip` for zip archives
  #   (real Ansible's own extra_opts only ever documents tar-oriented
  #   flags in practice; zip's own flag syntax is different enough that
  #   passing the same list through would usually just error).
  #
  # Not implemented: `copy` (crystal-ansible has no separate
  # controller-vs-target concept the way `copy: false` implies for a
  # locally-executed run - `src` is always read from wherever the task
  # executes, whether that's local or over SSH),
  # `io_buffer_size`, `validate_certs`, `decrypt` (vault auto-decryption -
  # `src` isn't read through `Vault.maybe_decrypt` here), SELinux options,
  # `unsafe_writes`, `attributes`.
  class UnarchivePlugin < BasePlugin
    MAX_REDIRECTS = 10

    def execute : PluginResult
      src = @params["src"]?
      dest = @params["dest"]?
      unless src && dest
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: src and dest are both required")
      end

      if creates = @params["creates"]?
        expanded_creates = expand_tilde(creates)
        if remote_file_exists?(expanded_creates) || remote_dir_exists?(expanded_creates)
          return PluginResult.new(changed: false, failed: false, msg: "Skipped: #{creates} already exists")
        end
      end

      # Real bug found benchmarking geerlingguy.node_exporter's own
      # "Download and unarchive node_exporter into temporary location."
      # task: `src: "{{ node_exporter_download_url }}"` (a real HTTPS
      # URL) with `remote_src: true`. Real Ansible's own unarchive
      # module explicitly documents this combination - "If remote_src
      # is yes and src contains ://, the remote machine will download
      # the file from the url first" - previously entirely
      # unimplemented here (the class doc above's own claim that
      # remote_src "has no effect" was simply wrong for this case):
      # `src` went straight to `remote_file_exists?`, which checks for
      # a local FILE PATH on the target, always false for a URL,
      # failing every such task outright with "Source ... failed to
      # transfer" even though the URL itself was perfectly reachable.
      tmp_download_path = nil
      if src.starts_with?("http://") || src.starts_with?("https://")
        tmp_download_path = "/tmp/.crystal-ansible-unarchive-#{Random.rand(100000..999999)}"
        begin
          download(src, tmp_download_path)
        rescue ex
          return PluginResult.new(changed: false, failed: true, msg: "Source '#{src}' failed to transfer: #{ex.message}")
        end
        src = tmp_download_path
      end

      unless remote_file_exists?(src)
        return PluginResult.new(changed: false, failed: true, msg: "Source '#{src}' failed to transfer")
      end

      unless remote_dir_exists?(dest)
        return PluginResult.new(changed: false, failed: true, msg: "dest '#{dest}' must be an existing dir")
      end

      begin
        run(src, dest)
      ensure
        File.delete(tmp_download_path) if tmp_download_path && File.exists?(tmp_download_path)
      end
    end

    # Binary-safe download with redirect-following - matches get_url.cr's
    # own #download (a downloaded release tarball is arbitrary binary
    # data, and GitHub's own release-asset URLs are themselves a 302
    # redirect to a signed S3/Azure blob URL, so following redirects
    # isn't optional here).
    private def download(url : String, tmp_path : String, redirects_left : Int32 = MAX_REDIRECTS)
      raise "too many redirects" if redirects_left < 0

      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 15.seconds
      client.read_timeout = 30.seconds

      client.get(uri.request_target, headers: HTTP::Headers{"User-Agent" => "ansible-httpget"}) do |response|
        if response.status.redirection? && (location = response.headers["Location"]?)
          client.close
          resolved = URI.parse(location).absolute? ? location : URI.parse(url).resolve(location).to_s
          return download(resolved, tmp_path, redirects_left - 1)
        end

        raise "server returned #{response.status_code}" unless response.status.success?

        File.open(tmp_path, "w") { |file| IO.copy(response.body_io, file) }
      end
    ensure
      client.try(&.close)
    end

    private def detect_handler(src : String) : Symbol?
      return :tar if remote_exec("tar tf #{src} > /dev/null 2>&1")[:exit_code] == 0
      return :zip if remote_exec("unzip -l #{src} > /dev/null 2>&1")[:exit_code] == 0
      nil
    end

    private def run(src : String, dest : String) : PluginResult
      exclude = (@params["exclude"]? || "").split(",").map(&.strip).reject(&.empty?)
      include_files = (@params["include"]? || "").split(",").map(&.strip).reject(&.empty?)
      keep_newer = is_true?(@params["keep_newer"]?, default: false)
      list_files = is_true?(@params["list_files"]?, default: false)
      # extra_opts - passed straight through to `tar`, real Ansible's own
      # documented behavior (raw flags like `--strip-components=1`, the
      # standard way to unpack a GitHub-release-style tarball whose
      # single top-level directory shouldn't be preserved). Previously
      # entirely unimplemented (silently dropped) - a role using it
      # unpacked WITH the top-level directory still present, so every
      # path the role expected directly under dest/ (robertdebock.
      # phpmyadmin's own dest/index.php) was actually one level deeper
      # and missing.
      extra_opts = (@params["extra_opts"]? || "").split(",").map(&.strip).reject(&.empty?)

      handler = detect_handler(src)
      unless handler
        return PluginResult.new(changed: false, failed: true, msg: "Unsupported archive format for #{src}")
      end

      changed = handler == :tar ? tar_changed?(src, dest, exclude, include_files, keep_newer, extra_opts) : zip_changed?(src, dest, exclude, include_files)

      if changed
        result = handler == :tar ? extract_tar(src, dest, exclude, include_files, keep_newer, extra_opts) : extract_zip(src, dest, exclude, include_files, keep_newer)
        unless result
          return PluginResult.new(changed: false, failed: true, msg: "failed to extract #{src}")
        end
      end

      apply_dest_attributes(dest)
      stat_fields = dest_stat_fields(dest)

      files = list_files ? members(handler, src) : nil

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: "",
        src: src,
        dest: dest,
        handler: handler == :tar ? "TgzArchive" : "ZipArchive",
        state: "directory",
        size: stat_fields[:size],
        uid: stat_fields[:uid],
        gid: stat_fields[:gid],
        owner: stat_fields[:owner],
        group: stat_fields[:group],
        mode: stat_fields[:mode],
        files: files || [] of String
      )
    end

    private def members(handler : Symbol, src : String) : Array(String)
      cmd = handler == :tar ? "tar tf #{src}" : "unzip -Z1 #{src}"
      remote_exec(cmd)[:stdout].split("\n").map(&.strip).reject(&.empty?)
    end

    private def tar_flags(exclude : Array(String), include_files : Array(String), keep_newer : Bool, extra_opts : Array(String) = [] of String) : String
      String.build do |str|
        str << " --keep-newer-files" if keep_newer
        extra_opts.each { |opt| str << " #{opt}" }
        exclude.each { |pattern| str << " --exclude=\"#{pattern}\"" }
        str << " " << include_files.map { |path| "\"#{path}\"" }.join(" ") unless include_files.empty?
      end
    end

    # A meaningful-difference line from `tar --compare`'s own output -
    # matches real Ansible's TgzArchive#is_unarchived exactly (down to
    # the regex set), NOT a raw exit-code check. GNU tar's own exit code
    # from --compare is nonzero for CATEGORIES of output crystal-ansible
    # must NOT treat as "changed": most notably the bogus "Cannot stat:
    # No such file or directory" warning `--strip-components` itself
    # always emits for the now-empty top-level path it stripped away -
    # real bug found benchmarking robertdebock.phpmyadmin's own
    # extra_opts: ['--strip-components=1'] unpack, previously always
    # non-idempotent (every rerun re-extracted and reported changed:
    # true) purely because of that one benign warning line, verified via
    # real ansible-playbook staying changed: false on the identical
    # rerun.
    MEANINGFUL_DIFF_PATTERNS = [
      /: Uid differs$/, /: Gid differs$/, /: Mode differs$/, /: Mod time differs$/,
      /: Invalid owner/, /: Invalid group/, /: Symlink differs$/,
    ]
    EMPTY_FILE_WARNING = /: : Warning: Cannot stat: No such file or directory$/
    MISSING_FILE_WARNING = /: Warning: Cannot stat: No such file or directory$/

    private def tar_changed?(src : String, dest : String, exclude : Array(String), include_files : Array(String), keep_newer : Bool, extra_opts : Array(String) = [] of String) : Bool
      cmd = "tar --compare -C #{dest} -f #{src}#{tar_flags(exclude, include_files, keep_newer, extra_opts)}"
      result = remote_exec(cmd)
      lines = (result[:stdout].split("\n") + result[:stderr].split("\n"))

      lines.any? do |line|
        next false if EMPTY_FILE_WARNING.matches?(line)
        MEANINGFUL_DIFF_PATTERNS.any? { |pattern| pattern.matches?(line) } || MISSING_FILE_WARNING.matches?(line)
      end
    end

    private def extract_tar(src : String, dest : String, exclude : Array(String), include_files : Array(String), keep_newer : Bool, extra_opts : Array(String) = [] of String) : Bool
      cmd = "tar --extract -C #{dest} -f #{src}#{tar_flags(exclude, include_files, keep_newer, extra_opts)}"
      remote_exec(cmd)[:exit_code] == 0
    end

    private def zip_flags(exclude : Array(String), include_files : Array(String)) : String
      String.build do |str|
        str << " " << include_files.map { |path| "\"#{path}\"" }.join(" ") unless include_files.empty?
        str << " -x " << exclude.map { |pattern| "\"#{pattern}\"" }.join(" ") unless exclude.empty?
      end
    end

    # Approximation of real Ansible's much more involved zipinfo/
    # permission-based idempotency check: compares each member file's
    # content checksum (from inside the zip) against what's already at
    # dest/member, ignoring members that are directories.
    private def zip_changed?(src : String, dest : String, exclude : Array(String), include_files : Array(String)) : Bool
      wanted = members(:zip, src).reject(&.ends_with?("/"))
      wanted = wanted.select { |member| include_files.empty? || include_files.includes?(member) }
      wanted = wanted.reject { |member| exclude.includes?(member) }

      wanted.any? do |member|
        dest_path = File.join(dest, member)
        return true unless remote_file_exists?(dest_path)

        archive_checksum = remote_exec("unzip -p #{src} \"#{member}\" 2>/dev/null | md5sum")[:stdout].strip
        dest_checksum = remote_exec("md5sum < #{dest_path} 2>/dev/null")[:stdout].strip
        archive_checksum.split(" ").first? != dest_checksum.split(" ").first?
      end
    end

    private def extract_zip(src : String, dest : String, exclude : Array(String), include_files : Array(String), keep_newer : Bool) : Bool
      overwrite_flag = keep_newer ? "-n" : "-o"
      cmd = "unzip -q #{overwrite_flag} -d #{dest} #{src}#{zip_flags(exclude, include_files)}"
      remote_exec(cmd)[:exit_code] == 0
    end

    private def apply_dest_attributes(dest : String)
      if owner = @params["owner"]?
        remote_exec("chown #{owner} #{dest}")
      end
      if group = @params["group"]?
        remote_exec("chgrp #{group} #{dest}")
      end
      if mode = @params["mode"]?
        remote_exec("chmod #{mode} #{dest}")
      end
    end

    private def dest_stat_fields(dest : String) : NamedTuple(size: Int64, uid: Int64, gid: Int64, owner: String, group: String, mode: String)
      result = remote_exec("stat -c '%s|%u|%g|%U|%G|%a' #{dest} 2>/dev/null")
      fields = result[:stdout].strip.split("|")

      if result[:exit_code] == 0 && fields.size == 6
        {
          size:  fields[0].to_i64,
          uid:   fields[1].to_i64,
          gid:   fields[2].to_i64,
          owner: fields[3],
          group: fields[4],
          mode:  "0#{fields[5]}",
        }
      else
        {size: 0_i64, uid: 0_i64, gid: 0_i64, owner: "", group: "", mode: ""}
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::UnarchivePlugin.new(config)
plugin.run
