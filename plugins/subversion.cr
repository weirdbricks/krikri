#!/usr/bin/env crystal

# subversion module (ansible.builtin.subversion) - checks out/updates an
# SVN working copy via the real `svn` binary, same approach real
# Ansible's own module takes (it shells out to svn too, no pysvn/python
# binding).
#
# Parameters:
#   repo (required): repository URL
#   dest: local working copy path (required unless checkout=no, update=no,
#     and export=no, mirroring real Ansible)
#   revision (optional, default "HEAD"): revision to check out/update to
#   force (optional, default no): discard local modifications
#   username/password (optional): passed via --username/--password
#   executable (optional): svn binary path (default "svn")
#   export (optional, default no): `svn export` instead of checkout/update
#   checkout (optional, default yes): perform initial checkout when dest
#     has no working copy yet
#   update (optional, default yes): run `svn update` on an existing
#     working copy
#   switch (optional, default yes): run `svn switch` when the working
#     copy's URL differs from repo
#   in_place (optional, default no): re-check out over an existing
#     non-svn directory instead of failing
#   validate_certs (optional, default no): when no (the default), passes
#     --trust-server-cert to svn, like real Ansible

require "json"
require "../src/krikri/base_plugin"

module Krikri
  class SubversionPlugin < BasePlugin
    # ansible.builtin.subversion's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.subversion). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[checkout export force in_place switch update validate_certs]
    end

    REVISION_LINE_RE = /^\w+\s?:\s+\d+$/
    URL_LINE_RE      = /^URL\s?:/

    # Real main()'s `svn_path = module.params['executable'] or
    # module.get_bin_path('svn', True)` - a bare lookup with NO existence
    # check of its own when `executable:` is given, and the dest-required
    # check that follows it runs BEFORE any svn command is ever spawned.
    # Set once in #execute so the per-operation spawn check can name the
    # binary the way real's failure does.
    @svn_path : String? = nil
    @svn_auth_display : Array(String) = [] of String
    # Cached answer to "can this svn_path be spawned at all?", probed
    # once, on the first operation that would actually run.
    @svn_exec_errno : Int32? = nil
    @svn_exec_errno_probed : Bool = false

    def execute : PluginResult
      validate_bool_params!
      repo = @params["repo"]?
      return missing_param("repo") unless repo

      checkout = true?(@params["checkout"]?, default: true)
      do_update = true?(@params["update"]?, default: true)
      do_switch = true?(@params["switch"]?, default: true)
      export = true?(@params["export"]?)
      in_place = true?(@params["in_place"]?)
      validate_certs = true?(@params["validate_certs"]?)
      revision = @params["revision"]? || "HEAD"
      force = true?(@params["force"]?)
      check_mode = true?(@params["_ansible_check_mode"]?)
      # module.params['executable'] or module.get_bin_path('svn', True).
      # Real does NOT stat or probe an `executable:` it was handed - the
      # only lookup here that can fail is get_bin_path for the default,
      # and the dest-required check below runs before any svn command is
      # spawned, so a bad `executable:` loses to it.
      svn = @params["executable"]?.presence
      if svn.nil?
        unless remote_exec("command -v svn >/dev/null 2>&1")[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: missing_executable_message("svn"))
        end
        svn = "svn"
        # The default lookup already proved this binary is on PATH and
        # executable - real's Popen can spawn it, so no per-operation
        # probe is needed for it.
        @svn_exec_errno_probed = true
      end
      @svn_path = svn
      @svn_auth_display = auth_display_args(validate_certs)
      auth = build_auth_args(validate_certs)

      dest = @params["dest"]?
      if dest.nil? || dest.empty?
        if checkout || do_update || export
          return PluginResult.new(changed: false, failed: true, msg: "the destination directory must be specified unless checkout=no, update=no, and export=no")
        end
        # Real's get_remote_revision() is the only svn call this branch
        # makes, so its `info` is the command a bad binary is named under.
        if failure = spawn_failure(["info", repo])
          return failure
        end
        after = remote_revision(svn, repo, auth)
        return PluginResult.new(changed: false, failed: false, after: after)
      end
      dest = expand_tilde(dest)

      dest_exists = remote_dir_exists?(dest)
      is_svn_repo = dest_exists && remote_dir_exists?(File.join(dest, ".svn"))

      if export || !dest_exists
        # Real module reports check-mode changed before the checkout=no
        # no-op check, so checkout=no in check mode still reports changed.
        return PluginResult.new(changed: true, failed: false) if check_mode

        if !export && !checkout
          return PluginResult.new(changed: false, failed: false)
        end

        if export
          run_export(svn, repo, dest, revision, force, auth)
        else
          checkout(svn, repo, dest, revision, auth)
        end
      elsif is_svn_repo
        unless do_update
          return PluginResult.new(changed: false, failed: false)
        end
        update(svn, repo, dest, revision, force, auth, check_mode, do_switch)
      elsif in_place
        result = checkout(svn, repo, dest, revision, auth, force: true)
        remote_exec("#{svn} revert -R #{shell_quote(dest)}") if force && !result.failed?
        result
      else
        PluginResult.new(changed: false, failed: true, msg: "ERROR: #{dest} folder already exists, but its not a subversion repository.")
      end
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "missing required argument: #{name}")
    end

    # Real's Subversion._exec argv prefix, in real's own order: the
    # global options come BEFORE the operation args, which is the order
    # basic.py's `_clean_args` space-joins into the `cmd` it reports when
    # the spawn fails. (The command krikri actually RUNS keeps
    # #build_auth_args's own spelling, which puts them after the
    # subcommand just as svn itself accepts them either way - only the
    # reported `cmd` has to match real byte for byte.)
    private def auth_display_args(validate_certs : Bool) : Array(String)
      args = ["--non-interactive", "--no-auth-cache"]
      args << "--trust-server-cert" unless validate_certs
      if username = @params["username"]?
        args << "--username" << username
      end
      if password = @params["password"]?
        args << "--password" << password
      end
      args
    end

    # Real's Subversion._exec hands its argv to module.run_command, and
    # basic.py's handler for the OSError a non-spawnable svn_path raises
    # fail_jsons with rc = the errno (2 ENOENT, 13 EACCES), msg "Error
    # executing command.", the FULL argv space-joined as `cmd`, and
    # empty stdout/stderr (the errno text rides in the [ERROR] block
    # only). Real never runs a `--version` probe up front - only
    # has_option_password_from_stdin() does, and only when a password was
    # given - so the command named in the failure is whichever operation
    # the module reached FIRST. Checked per operation, in the order the
    # real module reaches them, with the probe result cached so only the
    # first one pays for it. Verified against ansible-playbook 2.19.11
    # for the checkout and export first invocations.
    private def spawn_failure(op : Array(String)) : PluginResult?
      return nil unless path = @svn_path
      unless @svn_exec_errno_probed
        @svn_exec_errno_probed = true
        @svn_exec_errno = exec_errno(path)
      end
      return nil unless errno = @svn_exec_errno

      cmd = ([path] + @svn_auth_display + op).join(' ')
      reason = errno == 13 ? "Permission denied" : "No such file or directory"
      PluginResult.new(changed: false, failed: true, msg: "Error executing command.",
        cmd: cmd, rc: errno, stdout: "", stdout_lines: [] of String,
        stderr: "", stderr_lines: [] of String,
        _ansible_error_detail: "Error executing command: [Errno #{errno}] #{reason}: b'#{path}'")
    end

    # A svn_path basic.py's Popen cannot exec at all: absent (ENOENT), or
    # present but not an executable file (EACCES) - a directory included.
    # Probed on the target through remote_exec, like every other svn call.
    private def exec_errno(path : String) : Int32?
      resolved = path
      unless path.includes?("/")
        resolved = remote_exec("command -v #{shell_quote(path)} 2>/dev/null")[:stdout].strip
        return 2 if resolved.empty?
      end
      return 2 if remote_exec("test -e #{shell_quote(resolved)}")[:exit_code] != 0
      return nil if remote_exec("test -x #{shell_quote(resolved)}")[:exit_code] == 0

      13
    end

    private def build_auth_args(validate_certs : Bool) : String
      args = [] of String
      if username = @params["username"]?
        args << "--username #{shell_quote(username)}"
      end
      if password = @params["password"]?
        args << "--password #{shell_quote(password)} --no-auth-cache"
      end
      args << "--non-interactive --no-auth-cache"
      args << "--trust-server-cert" unless validate_certs
      args.join(" ")
    end

    private def checkout(svn : String, repo : String, dest : String, revision : String, auth : String, force : Bool = false) : PluginResult
      op = ["checkout"]
      op << "--force" if force
      op += ["-r", revision, repo, dest]
      if failure = spawn_failure(op)
        return failure
      end

      parent = File.dirname(dest)
      remote_exec("mkdir -p #{shell_quote(parent)}")

      rev_flag = revision == "HEAD" ? "" : "-r #{shell_quote(revision)} "
      force_flag = force ? "--force " : ""
      result = remote_exec("#{svn} checkout #{force_flag}#{rev_flag}#{auth} #{shell_quote(repo)} #{shell_quote(dest)}")
      return svn_failure("checkout", result) unless result[:exit_code] == 0

      # Real module: a checkout into a fresh dest reports before: null
      # plus the ["Revision: N", "URL: ..."] pair from svn info.
      info = svn_info(svn, dest, auth)
      PluginResult.new(changed: true, failed: false, before: nil, after: [info[:rev_line], info[:url_line]])
    end

    private def run_export(svn : String, repo : String, dest : String, revision : String, force : Bool, auth : String) : PluginResult
      op = ["export"]
      op << "--force" if force
      op += ["-r", revision, repo, dest]
      if failure = spawn_failure(op)
        return failure
      end

      parent = File.dirname(dest)
      remote_exec("mkdir -p #{shell_quote(parent)}")

      rev_flag = revision == "HEAD" ? "" : "-r #{shell_quote(revision)} "
      force_flag = force ? "--force " : ""
      result = remote_exec("#{svn} export #{force_flag}#{rev_flag}#{auth} #{shell_quote(repo)} #{shell_quote(dest)}")
      return svn_failure("export", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false)
    end

    private def update(svn : String, repo : String, dest : String, revision : String, force : Bool, auth : String, check_mode : Bool, switch : Bool) : PluginResult
      # Real reaches is_svn_repo()'s `svn info` first, then switch and
      # update; one spawn failure names whichever of those comes first.
      if failure = spawn_failure(["info", dest])
        return failure
      end

      before_info = svn_info(svn, dest, auth)
      before = before_info[:revision]
      before_lines = [before_info[:rev_line], before_info[:url_line]]

      target_rev = revision == "HEAD" ? head_revision(svn, dest, auth) : revision

      if check_mode
        # Real module's check-mode path (needs_update) compares parsed
        # revision numbers and reports before/after as bare "Revision: N"
        # strings, not the [revision, URL] pair.
        if (b = before.to_i?) && (t = target_rev.to_i?)
          update_needed = b < t
        else
          update_needed = before != target_rev
        end
        return PluginResult.new(changed: update_needed, failed: false, before: before_info[:rev_line], after: "Revision: #{target_rev}")
      end

      switch_changed = false
      if switch
        switch_result = switch_to_repo(svn, repo, dest, revision, auth)
        if failure = switch_result[:failure]
          return failure
        end
        switch_changed = switch_result[:changed]
      end

      if force
        remote_exec("#{svn} revert -R #{shell_quote(dest)}")
      end

      if before == target_rev
        after_info = switch_changed ? svn_info(svn, dest, auth) : before_info
        return PluginResult.new(changed: switch_changed, failed: false, before: before_lines, after: [after_info[:rev_line], after_info[:url_line]])
      end

      rev_flag = revision == "HEAD" ? "" : "-r #{shell_quote(revision)} "
      force_flag = force ? "--force " : ""
      result = remote_exec("#{svn} update #{force_flag}#{rev_flag}#{auth} #{shell_quote(dest)}")
      return svn_failure("update", result) unless result[:exit_code] == 0

      after_info = svn_info(svn, dest, auth)
      PluginResult.new(changed: switch_changed || before != after_info[:revision], failed: false, before: before_lines, after: [after_info[:rev_line], after_info[:url_line]])
    end

    private def switch_to_repo(svn : String, repo : String, dest : String, revision : String, auth : String) : {changed: Bool, failure: PluginResult?}
      if failure = spawn_failure(["switch", "--revision", revision, repo, dest])
        return {changed: false, failure: failure}
      end

      current_url = working_copy_url(svn, dest, auth)
      return {changed: false, failure: nil} if current_url.empty? || current_url == repo

      result = remote_exec("#{svn} switch --revision #{shell_quote(revision)} #{auth} #{shell_quote(repo)} #{shell_quote(dest)}")
      if result[:exit_code] != 0
        return {changed: false, failure: svn_failure("switch", result)}
      end

      changed = result[:stdout].each_line.any? { |line| line =~ /^[ABDUCGE] / }
      {changed: changed, failure: nil}
    end

    private def current_revision(svn : String, dest : String, auth : String) : String
      result = remote_exec("#{svn} info #{auth} #{shell_quote(dest)} 2>/dev/null | grep '^Revision:' | awk '{print $2}'")
      result[:stdout].strip
    end

    # Mirrors real Ansible's get_revision(): one `svn info` run, parsed
    # into the bare revision number plus the full matched "Revision: N"
    # and "URL: ..." lines (the before/after result pair), with the real
    # module's "Unable to get ..." fallbacks.
    private def svn_info(svn : String, target : String, auth : String, rev : String = "") : {revision: String, rev_line: String, url_line: String}
      rev_flag = rev.empty? ? "" : "-r #{rev == "HEAD" ? "HEAD" : shell_quote(rev)} "
      result = remote_exec("#{svn} info #{rev_flag}#{auth} #{shell_quote(target)} 2>/dev/null")
      revision = ""
      rev_line = "Unable to get revision"
      url_line = "Unable to get URL"
      result[:stdout].each_line do |line|
        if revision.empty? && line =~ REVISION_LINE_RE
          revision = line.split(":").last.strip
          rev_line = line
        elsif url_line == "Unable to get URL" && line =~ URL_LINE_RE
          url_line = line
        end
      end
      {revision: revision, rev_line: rev_line, url_line: url_line}
    end

    private def head_revision(svn : String, dest : String, auth : String) : String
      head = svn_info(svn, dest, auth, rev: "HEAD")
      head[:revision].empty? ? current_revision(svn, dest, auth) : head[:revision]
    end

    private def working_copy_url(svn : String, dest : String, auth : String) : String
      result = remote_exec("#{svn} info #{auth} #{shell_quote(dest)} 2>/dev/null | grep '^URL:' | awk '{print $2}'")
      result[:stdout].strip
    end

    private def remote_revision(svn : String, repo : String, auth : String) : String
      info = svn_info(svn, repo, auth)
      info[:rev_line] == "Unable to get revision" ? "Unable to get remote revision" : info[:rev_line]
    end

    private def svn_failure(action : String, result) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "svn #{action} failed: #{result[:stderr].strip}", stdout: result[:stdout], stderr: result[:stderr])
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SubversionPlugin.new(config)
plugin.run
