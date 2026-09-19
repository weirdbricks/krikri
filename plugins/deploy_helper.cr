#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # deploy_helper plugin - manages the release-directory layout used
  # by the "capistrano-style" deploy pattern, a native port of
  # community.general.deploy_helper.
  #
  # Implemented against real deploy_helper.py's control flow:
  #   - directory layout: <path>/releases, <path>/shared, <path>/current
  #     (created for state=present/finalize when missing)
  #   - state=present: creates the layout, then a new release dir
  #     <releases>/<release> (release defaults to a timestamp
  #     YYYYmmddHHMMSS like real's own default, stored in the result's
  #     `release`/`new_release` return values so follow-up tasks can
  #     reference it via the registered variable)
  #   - state=unfinished: removes a release dir only if it is NOT
  #     pointed at by `current` (real's unfinished-cleanup semantics;
  #     an absent release dir is a no-op)
  #   - state=clean: removes all release dirs except the newest
  #     keep_releases (real's same rule; releases are sorted
  #     lexically, which for the timestamp names is chronological)
  #   - state=finalize: points `current` symlink at the release (or at
  #     shared when release is empty - real's behavior), creating the
  #     symlink atomically via ln -sfn
  #   - state=absent: removes the whole <path> tree
  #   - check mode: discovery runs for real, mutations are not run
  #
  # `new_release_state` (deprecated upstream arg) is accepted and
  # ignored, matching real's behavior of treating it as always
  # "create".
  class DeployHelperPlugin < BasePlugin
    private DEPLOY_STATES = %w[finalize absent clean present query unfinished]

    def execute : PluginResult
      path = @params["path"]?
      unless path
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: path")
      end

      state = @params["state"]? || "present"
      unless DEPLOY_STATES.includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: #{DEPLOY_STATES.join(", ")}, got: #{state}")
      end

      releases_path, shared_path, current_path, keep_releases = resolve_paths(path)
      release = @params["release"]?
      check_mode = true?(@params["_ansible_check_mode"]?)

      case state
      when "absent"
        return absent_path(path, check_mode)
      when "present"
        present(path, releases_path, shared_path, current_path, release, check_mode)
      when "unfinished"
        unfinished(releases_path, current_path, release, check_mode)
      when "clean"
        clean(releases_path, current_path, keep_releases, check_mode)
      when "finalize"
        do_finalize(current_path, release, shared_path, releases_path, check_mode)
      else # query
        query(releases_path)
      end
    end

    private def resolve_paths(path : String) : {String, String, String, Int32}
      releases_path = @params["releases_path"]? || "#{path}/releases"
      shared_path = @params["shared_path"]? || "#{path}/shared"
      current_path = @params["current_path"]? || "#{path}/current"
      keep_releases = @params["keep_releases"]?.try(&.to_i?) || 5
      {releases_path, shared_path, current_path, keep_releases}
    end

    private def absent_path(path : String, check_mode : Bool) : PluginResult
      exists = remote_exec("test -e #{Shell.single_quote(path)}")
      return PluginResult.new(changed: false, failed: false, msg: "") unless exists[:exit_code] == 0
      return PluginResult.new(changed: true, failed: false,
        msg: "path #{path} would be removed") if check_mode

      result = remote_exec("rm -rf #{Shell.single_quote(path)}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "failed to remove #{path}: #{result[:stderr].strip}")
      end
      PluginResult.new(changed: true, failed: false, msg: "")
    end

    # Creates the directory layout + new release dir. Returns the
    # release name via the result's `release`/`new_release` keys (real
    # module's return values, consumed via registered variables).
    private def present(path : String, releases_path : String, shared_path : String,
                        current_path : String, release : String?, check_mode : Bool) : PluginResult
      release ||= Time.utc.to_s("%Y%m%d%H%M%S")
      new_release_path = "#{releases_path}/#{release}"

      if check_mode
        return PluginResult.new(changed: true, failed: false,
          msg: "release #{release} would be created")
      end

      mk = remote_exec("mkdir -p #{[path, releases_path, shared_path, new_release_path, current_path].map { |dir| Shell.single_quote(dir) }.join(' ')}")
      unless mk[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "failed to create deploy layout: #{mk[:stderr].strip}")
      end

      PluginResult.new(changed: true, failed: false, msg: "release #{release} created", release: release, new_release: release)
    end

    # Removes a release dir only when it is not the one `current`
    # points at - real's unfinished-cleanup semantics (used to clean
    # up a failed deploy before retrying).
    private def unfinished(releases_path : String, current_path : String, release : String?, check_mode : Bool) : PluginResult
      unless release
        return PluginResult.new(changed: false, failed: true,
          msg: "state is unfinished but all of the following are missing: release")
      end

      release_path = "#{releases_path}/#{release}"
      exists = remote_exec("test -d #{Shell.single_quote(release_path)}")
      return PluginResult.new(changed: false, failed: false, msg: "") unless exists[:exit_code] == 0

      target = current_target(current_path)
      return PluginResult.new(changed: false, failed: true, msg: target) if target.is_a?(String)
      if target == release_path
        return PluginResult.new(changed: false, failed: true,
          msg: "Refusing to remove unfinished release #{release}: it is the current release")
      end

      return PluginResult.new(changed: true, failed: false,
        msg: "unfinished release #{release} would be removed") if check_mode

      result = remote_exec("rm -rf #{Shell.single_quote(release_path)}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "failed to remove #{release_path}: #{result[:stderr].strip}")
      end
      PluginResult.new(changed: true, failed: false, msg: "")
    end

    # Keeps the newest keep_releases release dirs (plus whatever
    # `current` points at, matching real's protect-the-current-release
    # rule) and removes the rest.
    private def clean(releases_path : String, current_path : String, keep_releases : Int32, check_mode : Bool) : PluginResult
      listing = remote_exec("ls -1 #{Shell.single_quote(releases_path)} 2>/dev/null")
      releases = listing[:exit_code] == 0 ? listing[:stdout].lines.map(&.strip).reject(&.empty?) : [] of String
      return PluginResult.new(changed: false, failed: false, msg: "") if releases.size <= keep_releases

      target = current_target(current_path)
      return PluginResult.new(changed: false, failed: true, msg: target) if target.is_a?(String)

      # Sorted lexically ascending; the newest are the last N. The
      # current release is always kept even when old.
      sorted = releases.sort
      to_remove = sorted[0...sorted.size - keep_releases].reject { |release| "#{releases_path}/#{release}" == target }

      return PluginResult.new(changed: true, failed: false,
        msg: "#{to_remove.size} old releases would be removed") if check_mode || to_remove.empty?

      args = to_remove.map { |release| Shell.single_quote("#{releases_path}/#{release}") }.join(' ')
      result = remote_exec("rm -rf #{args}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "failed to remove old releases: #{result[:stderr].strip}")
      end
      PluginResult.new(changed: true, failed: false,
        msg: "#{to_remove.size} old releases removed")
    end

    # Points the `current` symlink at the release dir (or at shared
    # when release is empty - real's documented behavior for
    # finalize's "no release given" case).
    private def do_finalize(current_path : String, release : String?, shared_path : String,
                            releases_path : String, check_mode : Bool) : PluginResult
      target = if release && !release.empty?
                 "#{releases_path}/#{release}"
               else
                 shared_path
               end

      exists = remote_exec("test -d #{Shell.single_quote(target)}")
      unless exists[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "release path #{target} does not exist")
      end

      existing = current_target(current_path)
      return PluginResult.new(changed: false, failed: true, msg: existing) if existing.is_a?(String)
      if existing == target
        return PluginResult.new(changed: false, failed: false,
          msg: "current already points at #{target}")
      end

      return PluginResult.new(changed: true, failed: false,
        msg: "current would be pointed at #{target}") if check_mode

      result = remote_exec("ln -sfn #{Shell.single_quote(target)} #{Shell.single_quote(current_path)}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "failed to update current symlink: #{result[:stderr].strip}")
      end
      PluginResult.new(changed: true, failed: false,
        msg: "current points at #{target}")
    end

    private def query(releases_path : String) : PluginResult
      listing = remote_exec("ls -1 #{Shell.single_quote(releases_path)} 2>/dev/null")
      releases = listing[:exit_code] == 0 ? listing[:stdout].lines.map(&.strip).reject(&.empty?) : [] of String
      PluginResult.new(changed: false, failed: false, msg: "", releases: releases)
    end

    # Resolves where the `current` symlink points (nil when it doesn't
    # exist yet), or an error message string when the probe fails.
    private def current_target(current_path : String) : String? | String
      result = remote_exec("readlink #{Shell.single_quote(current_path)} 2>/dev/null")
      return nil unless result[:exit_code] == 0
      out = result[:stdout].strip
      out.empty? ? nil : out
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DeployHelperPlugin.new(config)
plugin.run
