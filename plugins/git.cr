#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Git plugin - clones/updates a git repository
  # Compatible with (a subset of) Ansible's ansible.builtin.git module
  #
  # Parameters:
  #   repo (required): repository URL (or local path / file:// URL)
  #   dest (required): where to clone/update it
  #   version (optional, default "HEAD"): branch, tag, or commit sha to check out
  #   update (optional, default yes): fetch + update an already-cloned repo
  #   force (optional, default no): discard local changes when checking out
  #   depth (optional): shallow-clone depth
  class GitPlugin < BasePlugin
    def execute : PluginResult
      repo = @params["repo"]?
      return missing_param("repo") unless repo

      dest = @params["dest"]?
      return missing_param("dest") unless dest
      dest = expand_tilde(dest)

      version = @params["version"]? || "HEAD"
      update = @params["update"]?.nil? || is_true?(@params["update"]?)
      force = is_true?(@params["force"]?)
      check_mode = is_true?(@params["check_mode"]?)

      if Dir.exists?(File.join(dest, ".git"))
        update ? update_repo(dest, version, force, check_mode) : already_present(dest)
      else
        clone(repo, dest, version, check_mode)
      end
    end

    private def clone(repo : String, dest : String, version : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: true, failed: false, msg: "Would clone repository (check mode)") if check_mode

      parent = File.dirname(dest)
      Dir.mkdir_p(parent) unless Dir.exists?(parent)

      depth = @params["depth"]?
      depth_flag = depth ? "--depth #{depth} " : ""

      clone_result = remote_exec("git clone #{depth_flag}#{repo} #{dest}")
      return git_failure("clone repository", clone_result) unless clone_result[:exit_code] == 0

      if version != "HEAD"
        checkout_result = remote_exec("git -C #{dest} checkout #{version}")
        return git_failure("check out #{version}", checkout_result) unless checkout_result[:exit_code] == 0
      end

      PluginResult.new(changed: true, failed: false, msg: "Cloned repository", after: current_commit(dest))
    end

    private def update_repo(dest : String, version : String, force : Bool, check_mode : Bool) : PluginResult
      before = current_commit(dest)

      fetch_result = remote_exec("git -C #{dest} fetch origin")
      return git_failure("fetch", fetch_result) unless fetch_result[:exit_code] == 0

      target = resolve_ref(dest, version)
      return PluginResult.new(changed: false, failed: true, msg: "Could not resolve version: #{version}") unless target

      return PluginResult.new(changed: false, failed: false, msg: "Already up to date", before: before, after: before) if target == before
      return PluginResult.new(changed: true, failed: false, msg: "Would update repository (check mode)", before: before, after: target) if check_mode

      checkout_result = remote_exec("git -C #{dest} checkout #{force ? "-f " : ""}#{target}")
      return git_failure("check out #{target}", checkout_result) unless checkout_result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "Repository updated", before: before, after: target)
    end

    private def already_present(dest : String) : PluginResult
      PluginResult.new(changed: false, failed: false, msg: "Repository already exists (update: no)", after: current_commit(dest))
    end

    # Tries origin/<version> first (branches/tags as known by the remote),
    # falling back to <version> directly (exact commit shas, local refs).
    private def resolve_ref(dest : String, version : String) : String?
      ["origin/#{version}", version].each do |ref|
        result = remote_exec("git -C #{dest} rev-parse #{ref}")
        return result[:stdout].strip if result[:exit_code] == 0
      end
      nil
    end

    private def current_commit(dest : String) : String?
      result = remote_exec("git -C #{dest} rev-parse HEAD")
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
plugin = CrystalPlay::GitPlugin.new(config)
plugin.run
