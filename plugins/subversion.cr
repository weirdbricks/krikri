#!/usr/bin/env crystal

# subversion module (ansible.builtin.subversion) - checks out/updates an
# SVN working copy via the real `svn` binary, same approach real
# Ansible's own module takes (it shells out to svn too, no pysvn/python
# binding).
#
# Parameters:
#   repo (required): repository URL
#   dest (required): local working copy path
#   revision (optional, default "HEAD"): revision to check out/update to
#   force (optional, default no): discard local modifications
#   username/password (optional): passed via --username/--password
#   executable (optional): svn binary path (default "svn")

require "json"
require "../src/krikri/base_plugin"

module Krikri
  class SubversionPlugin < BasePlugin
    def execute : PluginResult
      repo = @params["repo"]?
      return missing_param("repo") unless repo

      dest = @params["dest"]?
      return missing_param("dest") unless dest
      dest = expand_tilde(dest)

      revision = @params["revision"]? || "HEAD"
      force = true?(@params["force"]?)
      check_mode = true?(@params["check_mode"]?)
      svn = @params["executable"]? || "svn"
      auth = build_auth_args

      if remote_dir_exists?(File.join(dest, ".svn"))
        update(svn, dest, revision, force, auth, check_mode)
      else
        checkout(svn, repo, dest, revision, auth, check_mode)
      end
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "missing required argument: #{name}")
    end

    private def build_auth_args : String
      args = [] of String
      if username = @params["username"]?
        args << "--username #{shell_quote(username)}"
      end
      if password = @params["password"]?
        args << "--password #{shell_quote(password)} --no-auth-cache"
      end
      args << "--non-interactive --trust-server-cert"
      args.join(" ")
    end

    private def checkout(svn : String, repo : String, dest : String, revision : String, auth : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: true, failed: false, msg: "Would check out repository (check mode)") if check_mode

      parent = File.dirname(dest)
      remote_exec("mkdir -p #{shell_quote(parent)}")

      rev_flag = revision == "HEAD" ? "" : "-r #{shell_quote(revision)} "
      result = remote_exec("#{svn} checkout #{rev_flag}#{auth} #{shell_quote(repo)} #{shell_quote(dest)}")
      return svn_failure("checkout", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "Checked out repository", after: current_revision(svn, dest, auth))
    end

    private def update(svn : String, dest : String, revision : String, force : Bool, auth : String, check_mode : Bool) : PluginResult
      before = current_revision(svn, dest, auth)

      if force
        remote_exec("#{svn} revert -R #{shell_quote(dest)}") unless check_mode
      end

      target_rev = revision == "HEAD" ? head_revision(svn, dest, auth) : revision

      if before == target_rev
        return PluginResult.new(changed: false, failed: false, msg: "already at revision #{before}", before: before, after: before)
      end

      return PluginResult.new(changed: true, failed: false, msg: "Would update from #{before} to #{target_rev} (check mode)", before: before, after: target_rev) if check_mode

      rev_flag = revision == "HEAD" ? "" : "-r #{shell_quote(revision)} "
      force_flag = force ? "--force " : ""
      result = remote_exec("#{svn} update #{force_flag}#{rev_flag}#{auth} #{shell_quote(dest)}")
      return svn_failure("update", result) unless result[:exit_code] == 0

      after = current_revision(svn, dest, auth)
      PluginResult.new(changed: before != after, failed: false, msg: "Updated to revision #{after}", before: before, after: after)
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
