#!/usr/bin/env crystal

# subversion module (ansible.builtin.subversion) - checks out/updates an
# SVN working copy via the real `svn` binary, same approach
# Ansible's own module takes (it shells out to svn too, no pysvn/python
# binding).
#
# Parameters:
#   repo (required): repository URL
#   dest: local working copy path (required unless checkout=no, update=no,
#     and export=no, mirroring Ansible)
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
#     --trust-server-cert to svn, like Ansible

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/krikri_jinja_filters"

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
    # binary the way Ansible's failure does.
    @svn_path : String? = nil
    @validate_certs : Bool = false
    # The password, when Ansible passes it on svn's STDIN rather than on the
    # command line (svn >= 1.10, see #ensure_version_probe).
    @svn_stdin_password : String? = nil
    # Cached answer to "can this svn_path be spawned at all?", probed
    # once, on the first operation that would actually run.
    @svn_exec_errno : Int32? = nil
    @svn_exec_errno_probed : Bool = false
    # Cached answer to Ansible's has_option_password_from_stdin() - the
    # `<svn> --version --quiet` probe _exec runs before every operation
    # when a password was given.
    @svn_version_probed : Bool = false
    @svn_supports_password_from_stdin : Bool = false
    @svn_version_failure : PluginResult? = nil

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
      # Ansible does NOT stat or probe an `executable:` it was handed - the
      # only lookup here that can fail is get_bin_path for the default,
      # and the dest-required check below runs before any svn command is
      # spawned, so a bad `executable:` loses to it.
      svn = @params["executable"]?.presence
      if svn.nil?
        # Real: module.get_bin_path('svn', required=True) - the RESOLVED
        # path (/usr/bin/svn) is what every reported `cmd` carries, not
        # the bare name.
        probe = remote_exec("command -v svn 2>/dev/null")
        if probe[:exit_code] != 0 || probe[:stdout].strip.empty?
          return PluginResult.new(changed: false, failed: true, msg: missing_executable_message("svn"))
        end
        svn = probe[:stdout].strip.split("\n").first
        # The default lookup already proved this binary is on PATH and
        # executable - Ansible's Popen can spawn it, so no per-operation
        # probe is needed for it.
        @svn_exec_errno_probed = true
      end
      @svn_path = svn
      @validate_certs = validate_certs

      dest = @params["dest"]?
      if dest.nil? || dest.empty?
        if checkout || do_update || export
          return PluginResult.new(changed: false, failed: true, msg: "the destination directory must be specified unless checkout=no, update=no, and export=no")
        end
        # Ansible's get_remote_revision() is the only svn call this branch
        # makes, so its `info` is the command a bad binary is named under.
        if failure = spawn_failure(["info", repo])
          return failure
        end
        after = remote_revision(svn, repo, auth_args)
        return PluginResult.new(changed: false, failed: false, after: after)
      end
      # Past Ansible's dest gate, so a password's `--version` probe may run
      # (see #ensure_version_probe) - and it decides how the password
      # itself is passed to every svn call below.
      if @params["password"]?
        if failure = ensure_version_probe
          return failure
        end
      end
      auth = auth_args
      dest = expand_tilde(dest)

      dest_exists = remote_dir_exists?(dest)
      is_svn_repo = dest_exists && remote_dir_exists?(File.join(dest, ".svn"))

      if export || !dest_exists
        # Ansible module reports check-mode changed before the checkout=no
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
        svn_exec("#{svn} revert -R #{auth} #{shell_quote(dest)}") if force && !result.failed?
        result
      else
        PluginResult.new(changed: false, failed: true, msg: "ERROR: #{dest} folder already exists, but its not a subversion repository.")
      end
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "missing required argument: #{name}")
    end

    # Ansible's Subversion._exec argv prefix, in Ansible's own order: the
    # global options come BEFORE the operation args, which is the order
    # basic.py's `_clean_args` space-joins into the `cmd` it reports when
    # the spawn fails. (The command krikri actually RUNS keeps
    # #auth_args's own spelling, which puts them after the subcommand just
    # as svn itself accepts them either way - only the reported `cmd` has
    # to match real byte for byte.) With a password and an svn that
    # supports it, Ansible passes `--password-from-stdin` and feeds the
    # password on the command's stdin instead of naming it in argv.
    private def auth_display_args : Array(String)
      args = ["--non-interactive", "--no-auth-cache"]
      args << "--trust-server-cert" unless @validate_certs
      if username = @params["username"]?
        args << "--username" << username
      end
      if password = @params["password"]?
        if @svn_supports_password_from_stdin
          args << "--password-from-stdin"
        else
          args << "--password" << password
        end
      end
      args
    end

    # The same argv prefix as it is executed (see
    # #auth_display_args), plus the stdin feed when the password is not
    # on the command line.
    private def auth_args : String
      args = [] of String
      if username = @params["username"]?
        args << "--username #{shell_quote(username)}"
      end
      if password = @params["password"]?
        if @svn_supports_password_from_stdin
          args << "--password-from-stdin"
          @svn_stdin_password = password
        else
          args << "--password #{shell_quote(password)} --no-auth-cache"
        end
      end
      args << "--non-interactive --no-auth-cache"
      args << "--trust-server-cert" unless @validate_certs
      args.join(" ")
    end

    # Ansible's Subversion.has_option_password_from_stdin(): `<svn> --version
    # --quiet` with check_rc=True, called from _exec BEFORE it finishes
    # assembling the operation argv and only when a password was given -
    # so it is the FIRST svn command of the run in that case, and its
    # non-zero rc is basic.py's own check_rc failure. nil when the probe
    # succeeded (its answer is cached in
    # @svn_supports_password_from_stdin), the failure result otherwise.
    private def ensure_version_probe : PluginResult?
      return @svn_version_failure if @svn_version_probed
      @svn_version_probed = true
      return nil unless path = @svn_path

      argv = [path, "--version", "--quiet"]
      # Popen raises before it ever reports an rc when the binary cannot
      # be spawned at all - same OSError the operation itself would hit.
      if errno = spawn_errno(path)
        return @svn_version_failure = spawn_error(path, errno, argv)
      end

      result = remote_exec(argv.map { |arg| shell_quote(arg) }.join(' '))
      if result[:exit_code] == 0
        @svn_supports_password_from_stdin = at_least_1_10?(result[:stdout])
        return nil
      end

      @svn_version_failure = check_rc_result(argv, result[:exit_code], result[:stdout], result[:stderr])
    end

    # LooseVersion(svn --version --quiet's stdout) >= LooseVersion('1.10.0')
    # - Ansible's has_option_password_from_stdin return value, which picks
    # --password-from-stdin over the insecure command-line --password.
    private def at_least_1_10?(reported : String) : Bool
      version = reported.strip.lines.first?.try(&.strip) || ""
      version = version.split(/[\s,]/).first? || ""
      KrikriJinjaFilters.compare_versions(version, "1.10.0") >= 0
    rescue
      false
    end

    # Ansible's Subversion._exec hands its argv to module.run_command, and
    # basic.py's handler for the OSError a non-spawnable svn_path raises
    # fail_jsons with rc = the errno (2 ENOENT, 13 EACCES), msg "Error
    # executing command.", the FULL argv as `cmd`, and empty
    # stdout/stderr (the errno text rides in the [ERROR] block only).
    # Ansible never runs a `--version` probe up front - EXCEPT through
    # has_option_password_from_stdin(), which _exec calls BEFORE it
    # assembles any operation argv, and only when a password was given
    # (that probe's own argv is just `<svn> --version --quiet`, no auth
    # args). So the command named in the failure is the version probe
    # when a password was given and the operation the module reached
    # FIRST otherwise. Checked per operation, in the order the real
    # module reaches them, with the probe result cached so only the first
    # one pays for it. Verified against ansible-playbook 2.19.11 for the
    # version, checkout and export first invocations.
    private def spawn_failure(op : Array(String)) : PluginResult?
      return nil unless path = @svn_path
      if errno = spawn_errno(path)
        argv = @params["password"]? ? [path, "--version", "--quiet"] : ([path] + auth_display_args + op)
        return spawn_error(path, errno, argv)
      end

      # The binary spawns: with a password, Ansible's first svn command is
      # still the --version probe, so its rc decides the outcome.
      @params["password"]? ? ensure_version_probe : nil
    end

    # The errno of the first svn command basic.py's Popen raises on
    # (cached: Ansible only ever tries to spawn once per module run).
    private def spawn_errno(path : String) : Int32?
      unless @svn_exec_errno_probed
        @svn_exec_errno_probed = true
        @svn_exec_errno = exec_errno(path)
      end
      @svn_exec_errno
    end

    # basic.py's OSError handler for a command Popen could not spawn.
    private def spawn_error(path : String, errno : Int32, argv : Array(String)) : PluginResult
      reason = errno == 13 ? "Permission denied" : "No such file or directory"
      PluginResult.new(changed: false, failed: true, msg: "Error executing command.",
        cmd: reported_cmd(argv), rc: errno, stdout: "", stdout_lines: [] of String,
        stderr: "", stderr_lines: [] of String,
        # real: fail_json(rc=errno, stdout='', stderr='', msg=..., cmd=...,
        # exception=ex) - kwargs lead in call order, failed/msg follow, the
        # controller appends the *_lines splits, then changed, then exception.
        key_order: ["rc", "stdout", "stderr", "cmd", "failed", "msg",
                    "stdout_lines", "stderr_lines", "changed", "exception"],
        _ansible_error_detail: "Error executing command: [Errno #{errno}] #{reason}: b'#{path}'")
    end

    # run_command(check_rc=True)'s own failure: msg is the bare rstripped
    # stderr and cmd/rc/stdout/stderr (plus the controller-derived
    # *_lines) ride along. fail_json always emits msg, even an empty one
    # (a silent svn that just exits non-zero).
    private def check_rc_result(argv : Array(String), rc : Int32, stdout : String, stderr : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: stderr.rstrip,
        include_empty_msg: true,
        cmd: reported_cmd(argv), rc: rc,
        stdout: stdout, stdout_lines: stdout.lines.map(&.chomp),
        stderr: stderr, stderr_lines: stderr.lines.map(&.chomp),
        # real: fail_json(cmd=clean_args, rc=, stdout=, stderr=, msg=)
        # - kwargs lead, failed/msg follow, the controller appends the
        # *_lines splits, then changed, then exception.
        key_order: ["cmd", "rc", "stdout", "stderr", "failed", "msg",
                    "stdout_lines", "stderr_lines", "changed", "exception"])
    end

    # The `cmd` string Ansible reports for an argv: basic.py's _clean_args
    # - every token through shlex.quote (Shell.quote_arg leaves a safe
    # token bare, exactly like shlex.quote), space-joined, with the
    # token AFTER a PASSWD_ARG_RE match replaced by ******** (Ansible's
    # redaction of the value it passed on the command line).
    private def reported_cmd(argv : Array(String)) : String
      rendered = [] of String
      redact_next = false
      argv.each do |arg|
        if redact_next
          redact_next = false
          rendered << "********"
          next
        end
        if arg =~ /^\-{0,2}pass[-]?(word|wd)?/
          if sep = arg.index('=')
            rendered << "#{arg[0, sep]}=********"
            next
          end
          redact_next = true
        end
        rendered << arg
      end
      rendered.map { |arg| Shell.quote_arg(arg) }.join(" ")
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

    # Every svn invocation, with Ansible's `data=password` stdin feed
    # reproduced as a printf pipe when the password is not on the command
    # line (run_command(bits, check_rc, data=stdin_data) hands svn the
    # password bytes with no trailing newline).
    private def svn_exec(command : String)
      if password = @svn_stdin_password
        remote_exec("printf '%s' #{shell_quote(password)} | #{command}")
      else
        remote_exec(command)
      end
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
      result = svn_exec("#{svn} checkout #{force_flag}#{rev_flag}#{auth} #{shell_quote(repo)} #{shell_quote(dest)}")
      return check_rc_result([svn] + auth_display_args + op, result[:exit_code], result[:stdout], result[:stderr]) unless result[:exit_code] == 0

      # Ansible module: a checkout into a fresh dest reports before: null
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
      result = svn_exec("#{svn} export #{force_flag}#{rev_flag}#{auth} #{shell_quote(repo)} #{shell_quote(dest)}")
      return check_rc_result([svn] + auth_display_args + op, result[:exit_code], result[:stdout], result[:stderr]) unless result[:exit_code] == 0

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
        # Ansible module's check-mode path (needs_update) compares parsed
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
        svn_exec("#{svn} revert -R #{auth} #{shell_quote(dest)}")
      end

      if before == target_rev
        after_info = switch_changed ? svn_info(svn, dest, auth) : before_info
        return PluginResult.new(changed: switch_changed, failed: false, before: before_lines, after: [after_info[:rev_line], after_info[:url_line]])
      end

      rev_flag = revision == "HEAD" ? "" : "-r #{shell_quote(revision)} "
      force_flag = force ? "--force " : ""
      result = svn_exec("#{svn} update #{force_flag}#{rev_flag}#{auth} #{shell_quote(dest)}")
      update_op = ["update"]
      update_op += ["-r", revision, dest]
      return check_rc_result([svn] + auth_display_args + update_op, result[:exit_code], result[:stdout], result[:stderr]) unless result[:exit_code] == 0

      after_info = svn_info(svn, dest, auth)
      PluginResult.new(changed: switch_changed || before != after_info[:revision], failed: false, before: before_lines, after: [after_info[:rev_line], after_info[:url_line]])
    end

    private def switch_to_repo(svn : String, repo : String, dest : String, revision : String, auth : String) : {changed: Bool, failure: PluginResult?}
      if failure = spawn_failure(["switch", "--revision", revision, repo, dest])
        return {changed: false, failure: failure}
      end

      current_url = working_copy_url(svn, dest, auth)
      return {changed: false, failure: nil} if current_url.empty? || current_url == repo

      result = svn_exec("#{svn} switch --revision #{shell_quote(revision)} #{auth} #{shell_quote(repo)} #{shell_quote(dest)}")
      if result[:exit_code] != 0
        switch_op = ["switch", "--revision", revision, repo, dest]
        return {changed: false, failure: check_rc_result([svn] + auth_display_args + switch_op, result[:exit_code], result[:stdout], result[:stderr])}
      end

      changed = result[:stdout].each_line.any? { |line| line =~ /^[ABDUCGE] / }
      {changed: changed, failure: nil}
    end

    private def current_revision(svn : String, dest : String, auth : String) : String
      result = svn_exec("#{svn} info #{auth} #{shell_quote(dest)} 2>/dev/null | grep '^Revision:' | awk '{print $2}'")
      result[:stdout].strip
    end

    # Mirrors Ansible's get_revision(): one `svn info` run, parsed
    # into the bare revision number plus the full matched "Revision: N"
    # and "URL: ..." lines (the before/after result pair), with the real
    # module's "Unable to get ..." fallbacks.
    private def svn_info(svn : String, target : String, auth : String, rev : String = "") : {revision: String, rev_line: String, url_line: String}
      rev_flag = rev.empty? ? "" : "-r #{rev == "HEAD" ? "HEAD" : shell_quote(rev)} "
      result = svn_exec("#{svn} info #{rev_flag}#{auth} #{shell_quote(target)} 2>/dev/null")
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
      result = svn_exec("#{svn} info #{auth} #{shell_quote(dest)} 2>/dev/null | grep '^URL:' | awk '{print $2}'")
      result[:stdout].strip
    end

    private def remote_revision(svn : String, repo : String, auth : String) : String
      info = svn_info(svn, repo, auth)
      info[:rev_line] == "Unable to get revision" ? "Unable to get remote revision" : info[:rev_line]
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
