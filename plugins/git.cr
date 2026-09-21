#!/usr/bin/env crystal

require "json"
require "file_utils"
require "../src/krikri/base_plugin"

module Krikri
  # Git plugin - clones/updates a git repository
  # Compatible with real Ansible's ansible.builtin.git module
  #
  # Parameters:
  #   repo (required): repository URL (or local path / file:// URL)
  #   dest (required unless clone: no): where to clone/update it
  #   version (default "HEAD"): branch, tag, or commit sha to check out
  #   update (default yes): fetch + update an already-cloned repo
  #   force (default no): discard local changes when checking out
  #   depth: shallow-clone depth
  #   remote (default "origin"): remote name used for clone/fetch
  #   refspec: extra refspec fetched before checkout
  #   key_file: SSH private key used via GIT_SSH_COMMAND
  #   ssh_opts: extra ssh options passed via GIT_SSH_COMMAND
  #   accept_hostkey (default no): StrictHostKeyChecking=no in the ssh options
  #   accept_newhostkey (default no): StrictHostKeyChecking=accept-new variant
  #   executable: path to the git binary to use
  #   clone (default yes): clone when dest has no repo yet; when no, only
  #     reports the remote head (ls-remote) and never clones
  #   recursive (default yes): clone/update submodules
  #   single_branch (default no): --single-branch clone
  #   bare (default no): clone as a bare repo
  #   separate_git_dir: place the git dir outside the working tree
  #   umask: octal umask applied around git operations
  #   reference: local reference/alternate repo passed to clone --reference
  #   track_submodules (default no): submodule update --remote
  #   verify_commit (default no): GPG-verify the checked-out commit/tag
  #   gpg_allowlist (list, alias gpg_whitelist): acceptable signing key
  #     fingerprints for verify_commit
  #   archive: create a tar/zip archive of the checked-out tree
  #   archive_prefix: path prefix inside the archive (requires archive)
  #
  # Validation mirrors real AnsibleModule: separate_git_dir/bare and
  # accept_hostkey/accept_newhostkey are mutually exclusive; archive_prefix
  # requires archive.
  class GitPlugin < BasePlugin
    @git_path : String = "git"
    @cmd_prefix : String = ""
    @repo : String = ""
    @version : String = "HEAD"
    @remote : String = "origin"
    @bare : Bool = false
    @force : Bool = false
    @depth : String?
    @refspec : String?
    @reference : String?
    @separate_git_dir : String?
    @gpg_allowlist : Array(String) = [] of String

    def execute : PluginResult
      if violation = validate_param_rules
        return violation
      end

      repo = @params["repo"]?
      return missing_param("repo") unless repo
      repo = expand_tilde(repo)
      # Real Ansible force-converts path-based repos to file:// so depth:
      # (which requires a protocol) works on local clones.
      repo = "file://#{repo}" if repo.starts_with?("/")
      @repo = repo

      dest = @params["dest"]?.try { |path| expand_tilde(path) }
      allow_clone = @params["clone"]?.nil? || true?(@params["clone"]?)
      if dest.nil? && allow_clone
        return PluginResult.new(changed: false, failed: true,
          msg: "the destination directory must be specified unless clone=no")
      end

      @version = @params["version"]? || "HEAD"
      @remote = @params["remote"]? || "origin"
      update = @params["update"]?.nil? || true?(@params["update"]?)
      @force = true?(@params["force"]?)
      @bare = true?(@params["bare"]?)
      recursive = @params["recursive"]?.nil? || true?(@params["recursive"]?)
      single_branch = true?(@params["single_branch"]?)
      track_submodules = true?(@params["track_submodules"]?)
      verify_commit = true?(@params["verify_commit"]?)
      check_mode = true?(@params["_ansible_check_mode"]?)
      @depth = @params["depth"]?
      @refspec = @params["refspec"]?
      @reference = @params["reference"]?
      @separate_git_dir = @params["separate_git_dir"]?.try { |path| File.expand_path(expand_tilde(path)) }
      archive = @params["archive"]?
      archive_prefix = @params["archive_prefix"]?
      @gpg_allowlist = parse_string_list(@params["gpg_allowlist"]? || @params["gpg_whitelist"]?)
      @git_path = @params["executable"]?.try { |path| expand_tilde(path) } || "git"
      @cmd_prefix = build_command_prefix

      # Relocate the git dir when separate_git_dir points somewhere else
      # (real Ansible's relocate_repo path in main()).
      relocated = false
      if dest && (sep = @separate_git_dir) && !@bare && (rp = repo_path_of(dest))
        if File.expand_path(rp) != File.expand_path(sep)
          return PluginResult.new(changed: false, failed: true,
            msg: "Separate-git-dir path #{sep} already exists.") if File.exists?(sep)
          return PluginResult.new(changed: true, failed: false,
            msg: "Would relocate git dir to #{sep} (check mode)") if check_mode
          FileUtils.mv(rp, sep)
          File.write(File.join(dest, ".git"), "gitdir: #{sep}")
          relocated = true
        end
      end

      existing = false
      if dest && (rp = repo_path_of(dest))
        existing = File.exists?(File.join(rp, "config"))
      end

      before : String? = nil
      local_mods = false
      remote_url_changed = false
      fresh_clone = false

      if !existing
        if check_mode || !allow_clone
          # Real Ansible does an ls-remote here instead of touching dest.
          # The cloning context (dest is nil) makes get_remote_head use the
          # repo URL directly instead of trying to read a local HEAD.
          head = get_remote_head(nil, @repo, @version)
          return PluginResult.new(changed: false, failed: true,
            msg: "Could not determine remote revision for #{@version}") unless head
          msg = check_mode ? "Would clone repository (check mode)" : "Repository information retrieved (clone: no)"
          return PluginResult.new(changed: true, failed: false, msg: msg, after: head)
        end
        fresh_clone = true
        return missing_param("dest") unless dest
        if fail = do_clone(dest, single_branch)
          return fail
        end
      elsif !update
        d = dest || return missing_param("dest")
        before = current_commit(d)
        if archive
          return PluginResult.new(changed: true, failed: false,
            msg: "Would create archive (check mode)", before: before, after: before) if check_mode
          ar = create_archive(d, archive, archive_prefix)
          return ar if ar.failed?
          return PluginResult.new(changed: ar.changed?, failed: false,
            msg: "Repository already exists (update: no)", before: before, after: before)
        end
        return PluginResult.new(changed: false, failed: false,
          msg: "Repository already exists (update: no)", before: before, after: before)
      else
        d = dest || return missing_param("dest")
        before = current_commit(d)
        local_mods = has_local_mods(d)
        if local_mods
          unless @force
            return PluginResult.new(changed: false, failed: true,
              msg: "Local modifications exist in the destination: #{d} (force=no).", before: before)
          end
          unless check_mode
            r = run_git("reset --hard HEAD", d)
            return git_failure("reset local modifications", r) unless r[:exit_code] == 0
          end
        end

        if check_mode
          remote_url = get_remote_url(d)
          remote_url_changed = remote_url ? !same_repo_location?(remote_url, @repo) : false
          head = get_remote_head(d, @remote, @version)
          return PluginResult.new(changed: false, failed: true,
            msg: "Could not determine remote revision for #{@version}") unless head
          return PluginResult.new(changed: before != head || remote_url_changed, failed: false,
            msg: "Would update repository (check mode)", before: before, after: head)
        end

        sur = set_remote_url(d)
        if fail = sur[:fail]
          return fail
        end
        remote_url_changed = sur[:changed]

        if fail = fetch_repo(d)
          return fail
        end
      end

      d = dest || return missing_param("dest")

      unless @bare
        if fail = switch_version(d, verify_commit)
          return fail
        end
      end

      submodules_changed = false
      if recursive && !@bare
        changed, probe_fail = submodules_probe(d, track_submodules)
        if probe_fail
          return probe_fail
        end
        submodules_changed = changed
        if submodules_changed
          if fail = submodule_update(d, track_submodules)
            return fail
          end
        end
      end

      archive_changed = false
      if archive
        ar = create_archive(d, archive, archive_prefix)
        return ar if ar.failed?
        archive_changed = ar.changed?
      end

      after = current_commit(d)
      changed = (before != after) || local_mods || submodules_changed ||
                remote_url_changed || relocated || archive_changed
      msg = if fresh_clone
              "Cloned repository"
            elsif changed
              "Repository updated"
            else
              "Already up to date"
            end
      PluginResult.new(changed: changed, failed: false, msg: msg, before: before, after: after)
    end

    # Real AnsibleModule argument validation: mutually_exclusive pairs and
    # required_by (both presence-based, not truthiness-based).
    private def validate_param_rules : PluginResult?
      if @params["separate_git_dir"]? && @params["bare"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: separate_git_dir|bare")
      end
      if @params["accept_hostkey"]? && @params["accept_newhostkey"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: accept_hostkey|accept_newhostkey")
      end
      if @params["archive_prefix"]? && @params["archive"]?.nil?
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required by 'archive_prefix': archive")
      end
      if params_any = @config["params"]?
        if raw_umask = params_any["umask"]?
          unless raw_umask.raw.is_a?(String)
            return PluginResult.new(changed: false, failed: true,
              msg: "umask must be defined as a quoted octal integer")
          end
          if @params["umask"]?.try { |value| value.to_i?(8).nil? }
            return PluginResult.new(changed: false, failed: true,
              msg: "umask must be an octal integer")
          end
        end
      end
      nil
    end

    # Builds the shell prefix applied to every git command: the umask for
    # operations that create files, plus the GIT_SSH_COMMAND export used by
    # git for ssh:// repos (real Ansible's set_git_ssh_env).
    private def build_command_prefix : String
      prefix = ""
      if u = @params["umask"]?
        prefix = "umask #{sq(u.strip)}; "
      end

      ssh_opts = @params["ssh_opts"]?
      accept_hostkey = true?(@params["accept_hostkey"]?)
      accept_newhostkey = true?(@params["accept_newhostkey"]?)
      key_file = @params["key_file"]?.try { |k| expand_tilde(k) }
      return prefix unless ssh_opts || accept_hostkey || accept_newhostkey || key_file

      opts = ssh_opts || ""
      if accept_hostkey && !opts.includes?("StrictHostKeyChecking=no") &&
         !opts.includes?("StrictHostKeyChecking=accept-new")
        opts = opts.empty? ? "-o StrictHostKeyChecking=no" : "#{opts} -o StrictHostKeyChecking=no"
      end
      if accept_newhostkey && ssh_supports_acceptnew?
        if !opts.includes?("StrictHostKeyChecking=no") && !opts.includes?("StrictHostKeyChecking=accept-new")
          opts = opts.empty? ? "-o StrictHostKeyChecking=accept-new" : "#{opts} -o StrictHostKeyChecking=accept-new"
        end
      end
      opts += " -o BatchMode=yes" unless opts.includes?("BatchMode=yes")
      if key_file
        opts += " -i #{key_file}"
        opts += " -o IdentitiesOnly=yes" unless opts.includes?("IdentitiesOnly=yes")
      end
      "#{prefix}export GIT_SSH_COMMAND=#{sq("ssh #{opts}".strip)}; "
    end

    # Real Ansible probes `ssh -o StrictHostKeyChecking=accept-new -V` before
    # using accept_newhostkey (warns and skips it on old ssh clients).
    private def ssh_supports_acceptnew? : Bool
      r = remote_exec("ssh -o StrictHostKeyChecking=accept-new -V")
      r[:exit_code] == 0
    end

    private def do_clone(dest : String, single_branch : Bool) : PluginResult?
      parent = File.dirname(dest)
      Dir.mkdir_p(parent) unless Dir.exists?(parent)

      cmd = "#{sq(@git_path)} clone"
      cmd += @bare ? " --bare" : " --origin #{sq(@remote)}"

      is_branch_or_tag = remote_branch?(nil, @repo, @version) || remote_tag?(nil, @repo, @version)
      branch_added = false
      if dep = @depth
        if @version == "HEAD" || @refspec
          cmd += " --depth #{dep}"
        elsif is_branch_or_tag
          cmd += " --depth #{dep} --branch #{sq(@version)}"
          branch_added = true
        else
          # Real Ansible warns and ignores depth for refs that cannot be
          # fetched directly (commit shas) - a full clone follows instead.
        end
      end
      if reference = @reference
        cmd += " --reference #{sq(reference)}"
      end
      if single_branch
        cmd += " --single-branch"
        cmd += " --branch #{sq(@version)}" if is_branch_or_tag && !branch_added
      end
      if sep_dir = @separate_git_dir
        cmd += " --separate-git-dir=#{sq(sep_dir)}"
      end
      cmd += " #{sq(@repo)} #{sq(dest)}"

      r = remote_exec(@cmd_prefix + cmd)
      return git_failure("clone repository", r) unless r[:exit_code] == 0

      if @bare && @remote != "origin"
        r = run_git("remote add #{sq(@remote)} #{sq(@repo)}", dest)
        return git_failure("add remote #{@remote}", r) unless r[:exit_code] == 0
      end

      if rs = @refspec
        depth_flag = @depth ? "--depth #{@depth} " : ""
        r = run_git("fetch #{depth_flag}#{sq(@remote)} #{sq(rs)}", dest)
        return git_failure("fetch refspec #{rs}", r) unless r[:exit_code] == 0
      end

      nil
    end

    # Real Ansible's fetch(): a minimal targeted refspec set under depth:,
    # a full --tags fetch otherwise.
    private def fetch_repo(d : String) : PluginResult?
      refspecs = [] of String
      depth_flag = ""
      if dep = @depth
        currenthead = get_head_branch(d)
        if rs = @refspec
          refspecs << rs
        elsif @version == "HEAD"
          refspecs << currenthead if currenthead
        elsif remote_branch?(d, @repo, @version)
          if currenthead != @version
            refspecs << "+refs/heads/#{@version}:refs/heads/#{@version}"
          end
          refspecs << "+refs/heads/#{@version}:refs/remotes/#{@remote}/#{@version}"
        elsif remote_tag?(d, @repo, @version)
          refspecs << "+refs/tags/#{@version}:refs/tags/#{@version}"
        end
        depth_flag = "--depth #{dep} " unless refspecs.empty?
      end

      tags_flag = ""
      if depth_flag.empty?
        if @bare
          refspecs = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"]
        else
          tags_flag = "--tags "
        end
        if rs = @refspec
          refspecs << rs
        end
      end

      # Real Ansible's arg order: git fetch [flags] <remote> [refspecs...]
      force_flag = @force ? "--force " : ""
      args = "fetch #{depth_flag}#{tags_flag}#{force_flag}#{sq(@remote)}"
      refspecs.each { |refspec| args += " #{sq(refspec)}" }

      r = run_git(args, d)
      r[:exit_code] == 0 ? nil : git_failure("download remote objects and refs", r)
    end

    # Real Ansible's switch_version(): branch-aware checkout + hard reset
    # against the remote-tracking ref.
    private def switch_version(d : String, verify_commit : Bool) : PluginResult?
      if @version == "HEAD"
        branch = get_head_branch(d)
        return git_failure("determine HEAD branch",
          {exit_code: 1, stdout: "", stderr: "could not determine HEAD branch"}) unless branch

        r = run_git("checkout --force #{sq(branch)}", d)
        return git_failure("checkout branch #{branch}", r) unless r[:exit_code] == 0
        r = run_git("reset --hard #{sq(@remote)}/#{sq(branch)} --", d)
        return git_failure("checkout branch #{branch}", r) unless r[:exit_code] == 0
      else
        if remote_branch?(d, @remote, @version)
          if (dep = @depth) && !local_branch?(d, @version)
            # git clone --depth implies --single-branch; fetch the requested
            # branch explicitly so the checkout below can succeed (real
            # Ansible's set_remote_branch).
            r = run_git("fetch --depth=#{dep} #{sq(@remote)} " \
                        "+refs/heads/#{sq(@version)}:refs/heads/#{sq(@version)} " \
                        "+refs/heads/#{sq(@version)}:refs/remotes/#{sq(@remote)}/#{sq(@version)}", d)
            return git_failure("fetch branch from remote: #{@version}", r) unless r[:exit_code] == 0
          end
          if !local_branch?(d, @version)
            r = run_git("checkout --track -b #{sq(@version)} #{sq(@remote)}/#{sq(@version)}", d)
            return git_failure("checkout #{@version}", r) unless r[:exit_code] == 0
          else
            r = run_git("checkout --force #{sq(@version)}", d)
            return git_failure("checkout branch #{@version}", r) unless r[:exit_code] == 0
            r = run_git("reset --hard #{sq(@remote)}/#{sq(@version)}", d)
            return git_failure("checkout branch #{@version}", r) unless r[:exit_code] == 0
          end
        else
          r = run_git("checkout --force #{sq(@version)}", d)
          return git_failure("checkout #{@version}", r) unless r[:exit_code] == 0
        end
      end

      if verify_commit
        if fail = verify_commit_sign(d)
          return fail
        end
      end
      nil
    end

    # Real Ansible's verify_commit_sign: verify-tag for annotated tags,
    # verify-commit otherwise; --raw + fingerprint comparison when a
    # gpg_allowlist is given.
    private def verify_commit_sign(d : String) : PluginResult?
      sub = annotated_tags(d).includes?(@version) ? "verify-tag" : "verify-commit"
      raw_flag = @gpg_allowlist.empty? ? "" : " --raw"
      r = run_git("#{sub}#{raw_flag} #{sq(@version)}", d)
      if r[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to verify GPG signature of commit/tag \"#{@version}\"")
      end
      unless @gpg_allowlist.empty?
        fingerprint = gpg_fingerprint(r[:stderr].empty? ? r[:stdout] : r[:stderr])
        if fingerprint.nil? || !@gpg_allowlist.includes?(fingerprint)
          return PluginResult.new(changed: false, failed: true,
            msg: "The gpg_allowlist does not include the public key \"#{fingerprint}\" for this commit")
        end
      end
      nil
    end

    private def annotated_tags(d : String) : Array(String)
      r = run_git("for-each-ref refs/tags/ --format #{sq("%(objecttype):%(refname:short)")}", d)
      return [] of String unless r[:exit_code] == 0
      r[:stdout].lines.compact_map do |line|
        type, _, name = line.strip.partition(":")
        name if type == "tag"
      end
    end

    # Real Ansible's get_gpg_fingerprint: the primary key fingerprint from
    # gpg's VALIDSIG line (index 11 for subkey-signed commits, else 2).
    private def gpg_fingerprint(output : String) : String?
      output.each_line do |line|
        data = line.split
        next unless data.size > 2 && data[1] == "VALIDSIG"
        return data.size == 11 ? data[11]? : data[2]
      end
      nil
    end

    # Real Ansible's submodules_fetch change detection: a new submodule
    # without a checked-out .git, or submodule state that moved after a
    # submodule-level fetch.
    private def submodules_probe(d : String, track_submodules : Bool) : {Bool, PluginResult?}
      gitmodules = File.join(d, ".gitmodules")
      return {false, nil} unless File.exists?(gitmodules)

      File.read(gitmodules).each_line do |line|
        next unless line.strip.starts_with?("path")
        path = line.split("=", 2)[1]?.try(&.strip)
        next unless path
        return {true, nil} unless File.exists?(File.join(d, path, ".git"))
      end

      before = submodule_revs(d, "HEAD")
      r = run_git("submodule foreach #{@git_path} fetch", d)
      return {false, git_failure("fetch submodules", r)} unless r[:exit_code] == 0

      if track_submodules
        after = submodule_revs(d, "#{@remote}/master")
        return {before != after, nil}
      end

      st = run_git("submodule status", d)
      return {false, git_failure("retrieve submodule status", st)} unless st[:exit_code] == 0
      moved = st[:stdout].each_line.any? do |line|
        line.starts_with?('+') || line.starts_with?('-')
      end
      {moved, nil}
    end

    private def submodule_revs(d : String, ref : String) : String
      r = run_git("submodule foreach #{@git_path} rev-parse #{sq(ref)}", d)
      r[:exit_code] == 0 ? r[:stdout] : ""
    end

    # Real Ansible's submodule_update: sync, then update --init --recursive
    # (with --remote for track_submodules and --force with force).
    private def submodule_update(d : String, track_submodules : Bool) : PluginResult?
      r = run_git("submodule sync", d)
      return git_failure("sync submodules", r) unless r[:exit_code] == 0

      args = "submodule update --init --recursive"
      args += " --remote" if track_submodules
      args += " --force" if @force
      r = run_git(args, d)
      r[:exit_code] == 0 ? nil : git_failure("init/update submodules", r)
    end

    # Real Ansible's create_archive: idempotent via byte comparison against
    # the existing archive when one is already present.
    private def create_archive(d : String, archive : String, archive_prefix : String?) : PluginResult
      fmt = {".zip" => "zip", ".gz" => "tar.gz", ".tar" => "tar", ".tgz" => "tgz"}[File.extname(archive)]?
      unless fmt
        return PluginResult.new(changed: false, failed: true,
          msg: "Unable to get file extension from archive file name : #{archive}")
      end
      prefix_args = archive_prefix ? " --prefix #{sq(archive_prefix)}" : ""
      version_arg = sq(@version)

      if File.exists?(archive)
        tmpdir = File.join(Dir.tempdir, "krikri-git-archive-#{Random::Secure.hex(8)}")
        Dir.mkdir_p(tmpdir)
        begin
          repo_name = @repo.split("/")[-1].gsub(".git", "")
          tmp_archive = File.join(tmpdir, "#{repo_name}.#{fmt}")
          r = run_git("archive --format #{fmt} --output #{sq(tmp_archive)}#{prefix_args} #{version_arg}", d)
          if r[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true,
              msg: "Failed to perform archive operation: #{r[:stderr].empty? ? r[:stdout] : r[:stderr]}")
          end
          changed = File.read(tmp_archive) != File.read(archive)
          FileUtils.mv(tmp_archive, archive) if changed
          archive_msg = changed ? "Archive updated" : "Archive up to date"
          PluginResult.new(changed: changed, failed: false, msg: archive_msg)
        ensure
          FileUtils.rm_rf(tmpdir)
        end
      else
        r = run_git("archive --format #{fmt} --output #{sq(expand_tilde(archive))}#{prefix_args} #{version_arg}", d)
        if r[:exit_code] != 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to perform archive operation: #{r[:stderr].empty? ? r[:stdout] : r[:stderr]}")
        end
        PluginResult.new(changed: true, failed: false, msg: "Archive created")
      end
    end

    # Real Ansible's has_local_mods: any non-untracked entry in
    # `git status --porcelain`.
    private def has_local_mods(d : String) : Bool
      return false if @bare
      r = run_git("status --porcelain", d)
      return false unless r[:exit_code] == 0
      r[:stdout].each_line.any? { |line| !line.strip.empty? && !line.starts_with?("??") }
    end

    # Real Ansible's get_remote_url: nil when git cannot answer (old git).
    private def get_remote_url(d : String) : String?
      r = run_git("ls-remote --get-url #{sq(@remote)}", d)
      r[:exit_code] == 0 ? r[:stdout].strip : nil
    end

    # Real Ansible's set_remote_url: only rewrites when the URL actually
    # changed; reports changed only when the old URL was readable.
    private def set_remote_url(d : String) : NamedTuple(changed: Bool, fail: PluginResult?)
      url = get_remote_url(d)
      if url.nil? || !same_repo_location?(url, @repo)
        r = run_git("remote set-url #{sq(@remote)} #{sq(@repo)}", d)
        if r[:exit_code] != 0
          return {changed: false, fail: git_failure("set a new url #{@repo} for #{@remote}", r)}
        end
        return {changed: !url.nil?, fail: nil}
      end
      {changed: false, fail: nil}
    end

    # Real Ansible's get_remote_head: resolves the remote SHA for version
    # without any local clone. target is the repo URL when cloning, the
    # remote name otherwise; dest is nil in the cloning case.
    private def get_remote_head(dest : String?, target : String, version : String) : String?
      if version == "HEAD"
        if dest.nil?
          r = run_git("ls-remote #{sq(target)} -h HEAD", nil)
        else
          branch = get_head_branch(dest)
          return nil unless branch
          r = run_git("ls-remote #{sq(target)} -h refs/heads/#{sq(branch)}", dest)
        end
      elsif remote_branch?(dest, target, version)
        r = run_git("ls-remote #{sq(target)} -h refs/heads/#{sq(version)}", dest)
      elsif remote_tag?(dest, target, version)
        r = run_git("ls-remote #{sq(target)} -t refs/tags/#{sq(version)}*", dest)
        return nil unless r[:exit_code] == 0
        # Prefer the dereferenced line for annotated tags (real Ansible).
        chosen : String? = nil
        r[:stdout].each_line do |line|
          if line.strip.ends_with?("#{version}^{}")
            chosen = line
            break
          elsif line.strip.ends_with?(version)
            chosen = line
          end
        end
        return chosen.try { |line| line.split[0]? }
      else
        # Appears to be a sha1 - return as-is (real Ansible).
        return version
      end

      return nil unless r[:exit_code] == 0
      r[:stdout].strip.empty? ? nil : r[:stdout].strip.split[0]
    end

    private def remote_branch?(dest : String?, target : String, version : String) : Bool
      r = run_git("ls-remote #{sq(target)} -h refs/heads/#{sq(version)}", dest)
      r[:exit_code] == 0 && r[:stdout].includes?(version)
    end

    private def remote_tag?(dest : String?, target : String, version : String) : Bool
      r = run_git("ls-remote #{sq(target)} -t refs/tags/#{sq(version)}", dest)
      r[:exit_code] == 0 && r[:stdout].includes?(version)
    end

    private def local_branch?(d : String, branch : String) : Bool
      r = run_git("branch --no-color -a", d)
      return false unless r[:exit_code] == 0
      lines = r[:stdout].lines.map(&.strip)
      lines.includes?(branch) || lines.includes?("* #{branch}")
    end

    private def detached_head?(d : String) : Bool
      r = run_git("branch --no-color -a", d)
      return false unless r[:exit_code] == 0
      r[:stdout].lines.any? do |line|
        stripped = line.strip
        stripped.starts_with?("* ") &&
          (stripped.includes?("no branch") || stripped.includes?("detached"))
      end
    end

    # Real Ansible's get_head_branch: HEAD's branch, falling back to
    # refs/remotes/<remote>/HEAD while in a detached-HEAD state.
    private def get_head_branch(d : String) : String?
      rp = repo_path_of(d) || return nil
      head_file = File.join(rp, "HEAD")
      head_file = File.join(rp, "refs", "remotes", @remote, "HEAD") if detached_head?(d)
      return nil unless File.exists?(head_file)

      raw = File.read(head_file).lines.first? || ""
      raw = raw.sub("refs/remotes/#{@remote}", "")
      newref = raw.split(" ").last? || ""
      newref.split("/").last?
    end

    # Real Ansible's get_repo_path: dest itself for bare repos, dest/.git
    # otherwise, following a "gitdir:" pointer file (separate_git_dir).
    private def repo_path_of(dest : String) : String?
      return dest if @bare
      dotgit = File.join(dest, ".git")
      return dotgit if Dir.exists?(dotgit)
      if File.file?(dotgit)
        data = File.read(dotgit).strip
        return nil unless data.starts_with?("gitdir: ")
        gitdir = data[8..].strip
        gitdir = File.expand_path(gitdir, dest) unless gitdir.starts_with?("/")
        return Dir.exists?(gitdir) ? gitdir : nil
      end
      nil
    end

    # Real Ansible's unfrackgitpath comparison: exact match, or equal
    # expanded local paths.
    private def same_repo_location?(a : String, b : String) : Bool
      return true if a == b
      return File.expand_path(a) == File.expand_path(b) if a.starts_with?("/") && b.starts_with?("/")
      false
    end

    private def run_git(args : String, dest : String?)
      cwd_part = dest ? "#{sq(@git_path)} -C #{sq(dest)}" : sq(@git_path)
      remote_exec("#{@cmd_prefix}#{cwd_part} #{args}")
    end

    private def sq(str : String) : String
      Shell.single_quote(str)
    end

    private def parse_string_list(value : String?) : Array(String)
      return [] of String unless value
      v = value.strip
      return [] of String if v.empty?
      parsed = JSON.parse(v) rescue nil
      if parsed && (arr = parsed.as_a?)
        strings = arr.compact_map(&.as_s?)
        return strings unless strings.empty?
      end
      v.split(",").map(&.strip).reject(&.empty?)
    end

    private def current_commit(dest : String) : String?
      result = run_git("rev-parse HEAD", dest)
      result[:exit_code] == 0 ? result[:stdout].strip : nil
    end

    private def git_failure(action : String, result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Failed to #{action}: #{result[:stderr].empty? ? result[:stdout] : result[:stderr]}")
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::GitPlugin.new(config)
plugin.run
