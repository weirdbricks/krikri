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
    def execute : PluginResult
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
      check_mode = true?(@params["check_mode"]?)
      svn = @params["executable"]? || "svn"
      auth = build_auth_args(validate_certs)

      dest = @params["dest"]?
      if dest.nil? || dest.empty?
        if checkout || do_update || export
          return PluginResult.new(changed: false, failed: true, msg: "the destination directory must be specified unless checkout=no, update=no, and export=no")
        end
        after = remote_revision(svn, repo, auth)
        return PluginResult.new(changed: false, failed: false, msg: "No checkout, update, or export requested", after: after)
      end
      dest = expand_tilde(dest)

      dest_exists = remote_dir_exists?(dest)
      is_svn_repo = dest_exists && remote_dir_exists?(File.join(dest, ".svn"))

      if export || !dest_exists
        # Real module reports check-mode changed before the checkout=no
        # no-op check, so checkout=no in check mode still reports changed.
        return PluginResult.new(changed: true, failed: false, msg: "Would #{export ? "export" : "check out"} repository (check mode)") if check_mode

        if !export && !checkout
          return PluginResult.new(changed: false, failed: false, msg: "checkout=no: not checking out missing working copy")
        end

        if export
          run_export(svn, repo, dest, revision, force, auth)
        else
          checkout(svn, repo, dest, revision, auth)
        end
      elsif is_svn_repo
        unless do_update
          return PluginResult.new(changed: false, failed: false, msg: "update=no: skipped update")
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
      parent = File.dirname(dest)
      remote_exec("mkdir -p #{shell_quote(parent)}")

      rev_flag = revision == "HEAD" ? "" : "-r #{shell_quote(revision)} "
      force_flag = force ? "--force " : ""
      result = remote_exec("#{svn} checkout #{force_flag}#{rev_flag}#{auth} #{shell_quote(repo)} #{shell_quote(dest)}")
      return svn_failure("checkout", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "Checked out repository", after: current_revision(svn, dest, auth))
    end

    private def run_export(svn : String, repo : String, dest : String, revision : String, force : Bool, auth : String) : PluginResult
      parent = File.dirname(dest)
      remote_exec("mkdir -p #{shell_quote(parent)}")

      rev_flag = revision == "HEAD" ? "" : "-r #{shell_quote(revision)} "
      force_flag = force ? "--force " : ""
      result = remote_exec("#{svn} export #{force_flag}#{rev_flag}#{auth} #{shell_quote(repo)} #{shell_quote(dest)}")
      return svn_failure("export", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "Exported repository")
    end

    private def update(svn : String, repo : String, dest : String, revision : String, force : Bool, auth : String, check_mode : Bool, switch : Bool) : PluginResult
      before = current_revision(svn, dest, auth)

      target_rev = revision == "HEAD" ? head_revision(svn, dest, auth) : revision

      if check_mode
        return PluginResult.new(changed: before != target_rev, failed: false, msg: "Would update from #{before} to #{target_rev} (check mode)", before: before, after: target_rev)
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
        after = switch_changed ? current_revision(svn, dest, auth) : before
        return PluginResult.new(changed: switch_changed, failed: false, msg: "already at revision #{after}", before: before, after: after)
      end

      rev_flag = revision == "HEAD" ? "" : "-r #{shell_quote(revision)} "
      force_flag = force ? "--force " : ""
      result = remote_exec("#{svn} update #{force_flag}#{rev_flag}#{auth} #{shell_quote(dest)}")
      return svn_failure("update", result) unless result[:exit_code] == 0

      after = current_revision(svn, dest, auth)
      PluginResult.new(changed: switch_changed || before != after, failed: false, msg: "Updated to revision #{after}", before: before, after: after)
    end

    private def switch_to_repo(svn : String, repo : String, dest : String, revision : String, auth : String) : {changed: Bool, failure: PluginResult?}
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

    private def head_revision(svn : String, dest : String, auth : String) : String
      result = remote_exec("#{svn} info #{auth} -r HEAD #{shell_quote(dest)} 2>/dev/null | grep '^Revision:' | awk '{print $2}'")
      rev = result[:stdout].strip
      rev.empty? ? current_revision(svn, dest, auth) : rev
    end

    private def working_copy_url(svn : String, dest : String, auth : String) : String
      result = remote_exec("#{svn} info #{auth} #{shell_quote(dest)} 2>/dev/null | grep '^URL:' | awk '{print $2}'")
      result[:stdout].strip
    end

    private def remote_revision(svn : String, repo : String, auth : String) : String
      result = remote_exec("#{svn} info #{auth} #{shell_quote(repo)} 2>/dev/null | grep '^Revision:' | awk '{print $2}'")
      result[:stdout].strip
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
