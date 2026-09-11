#!/usr/bin/env crystal
# community.general.homebrew - manages Homebrew packages via `brew`.
# Ported from community.general's homebrew module (round 300047:
# geerlingguy.mas uses it; previously unavailable -> rc=4 "unavailable
# modules").
#
# Supported here: name (list or comma-separated string, lowercased like
# the real module), state (present/installed, latest/upgraded, head,
# absent/removed/uninstalled, linked, unlinked), path (':'-separated brew
# search dirs), update_homebrew, upgrade_all (alias upgrade),
# install_options, upgrade_options, force_formula.
#
# Idempotency matches the real module: `brew info --json=v2` decides
# installed/outdated per requested name (matched against name/full_name/
# aliases/oldnames plus tap-prefixed spellings), then exactly the
# missing/outdated packages get install/upgrade commands. `brew update`
# contributes to changed only when its output isn't "Already up-to-date".
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/homebrew"

module Krikri
  class HomebrewPlugin < BasePlugin
    def execute : PluginResult
      packages = parse_names
      path = @params["path"]? || "/usr/local/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin"
      state = normalize_state(@params["state"]? || "present")
      unless state
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, installed, latest, upgraded, head, linked, unlinked, absent, removed, uninstalled, got #{@params["state"]?}")
      end

      brew_path = find_brew(path)
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to find required executable brew in paths: #{path}") unless brew_path

      changed = false
      changed_pkgs = [] of String
      unchanged_pkgs = [] of String

      if true?(@params["update_homebrew"]?)
        update = remote_exec("#{brew_path} update")
        return fail(update[:stderr]) if update[:exit_code] != 0
        if PluginHelpers::Homebrew.update_changed?(update[:stdout])
          changed = true
        end
      end

      if true?(@params["upgrade_all"]?)
        upgrade = remote_exec("#{brew_path} upgrade#{upgrade_options}")
        return fail(upgrade[:stderr]) if upgrade[:exit_code] != 0
        unless upgrade[:stdout].strip.empty?
          changed = true
        end
      end

      return finish(changed, changed_pkgs, unchanged_pkgs, packages) if packages.empty?

      invalid = packages.reject { |pkg| PluginHelpers::Homebrew.valid_package?(pkg) }
      unless invalid.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "Invalid package#{invalid.size > 1 ? "s" : ""}: #{invalid.join(", ")}")
      end

      info = remote_exec(PluginHelpers::Homebrew.info_command(brew_path, packages))
      return fail(info[:stderr].strip.empty? ? "Unknown failure with exit code #{info[:exit_code]}" : info[:stderr].strip) if info[:exit_code] != 0
      status = PluginHelpers::Homebrew.parse_info(info[:stdout], packages)
      return PluginResult.new(changed: false, failed: true, msg: "Unable to parse brew info output") unless status

      installed = packages.select { |pkg| status[pkg][:installed] }
      outdated = packages.select { |pkg| status[pkg][:outdated] }

      case state
      when "installed"
        to_install = packages - installed
        if to_install.empty?
          unchanged_pkgs.concat(packages)
        else
          r = remote_exec(PluginHelpers::Homebrew.install_command(brew_path, to_install, install_options, false, force_formula?))
          return fail(r[:stderr]) if r[:exit_code] != 0
          changed_pkgs.concat(to_install)
          changed = true
        end
      when "upgraded"
        to_install = packages - installed
        to_upgrade = installed & outdated
        if to_install.empty? && to_upgrade.empty?
          unchanged_pkgs.concat(packages)
        else
          unless to_install.empty?
            r = remote_exec(PluginHelpers::Homebrew.install_command(brew_path, to_install, install_options, false, force_formula?))
            return fail(r[:stderr]) if r[:exit_code] != 0
          end
          unless to_upgrade.empty?
            r = remote_exec(PluginHelpers::Homebrew.upgrade_command(brew_path, to_upgrade, install_options))
            return fail(r[:stderr]) if r[:exit_code] != 0
          end
          changed_pkgs.concat(to_install + to_upgrade)
          changed = true
        end
      when "head"
        to_install = packages - installed
        if to_install.empty?
          unchanged_pkgs.concat(packages)
        else
          r = remote_exec(PluginHelpers::Homebrew.install_command(brew_path, to_install, install_options, true, force_formula?))
          return fail(r[:stderr]) if r[:exit_code] != 0
          changed_pkgs.concat(to_install)
          changed = true
        end
      when "absent"
        to_uninstall = installed & packages
        if to_uninstall.empty?
          unchanged_pkgs.concat(packages)
        else
          r = remote_exec(PluginHelpers::Homebrew.uninstall_command(brew_path, to_uninstall, install_options))
          return fail(r[:stderr]) if r[:exit_code] != 0
          changed_pkgs.concat(to_uninstall)
          changed = true
        end
      when "linked", "unlinked"
        missing = packages - installed
        unless missing.empty?
          return PluginResult.new(changed: false, failed: true,
            msg: "Package#{missing.size > 1 ? "s" : ""} not installed: #{missing.join(", ")}.")
        end
        r = remote_exec(PluginHelpers::Homebrew.link_command(brew_path, packages, install_options, unlink: state == "unlinked"))
        return fail(r[:stderr]) if r[:exit_code] != 0
        changed_pkgs.concat(packages)
        changed = true
      end

      finish(changed, changed_pkgs, unchanged_pkgs, packages)
    end

    private def fail(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg.strip)
    end

    private def finish(changed : Bool, changed_pkgs : Array(String), unchanged_pkgs : Array(String), packages : Array(String)) : PluginResult
      msg = changed_pkgs.size + unchanged_pkgs.size > 1 ? "Changed: #{changed_pkgs.size}, Unchanged: #{unchanged_pkgs.size}" : ""
      PluginResult.new(changed: changed, failed: false, msg: msg,
        changed_pkgs: changed_pkgs, unchanged_pkgs: unchanged_pkgs)
    end

    private def parse_names : Array(String)
      raw = @params["name"]?
      return [] of String unless raw

      begin
        parsed = JSON.parse(raw)
        list = parsed.as_a?.try(&.map(&.as_s)) if parsed.as_a?
        return list.compact.map(&.downcase) if list
      rescue
      end

      raw.split(",").map(&.strip.downcase).reject(&.empty?)
    end

    private def normalize_state(value : String) : String?
      case value
      when "present", "installed"          then "installed"
      when "latest", "upgraded"            then "upgraded"
      when "head"                          then "head"
      when "linked"                        then "linked"
      when "unlinked"                      then "unlinked"
      when "absent", "removed", "uninstalled" then "absent"
      end
    end

    private def find_brew(path : String) : String?
      check = remote_exec("command -v brew")
      return check[:stdout].strip if check[:exit_code] == 0 && !check[:stdout].strip.empty?

      path.split(":").each do |dir|
        candidate = "#{dir}/brew"
        test = remote_exec("test -x #{candidate} && echo found")
        return candidate if test[:exit_code] == 0 && test[:stdout].includes?("found")
      end
      nil
    end

    private def install_options : Array(String)
      parse_list_param(@params["install_options"]?)
    end

    private def upgrade_options : String
      opts = parse_list_param(@params["upgrade_options"]?).map { |opt| opt.starts_with?("--") ? opt : "--#{opt}" }
      opts.empty? ? "" : " #{opts.join(" ")}"
    end

    private def parse_list_param(raw : String?) : Array(String)
      return [] of String unless raw
      begin
        parsed = JSON.parse(raw)
        list = parsed.as_a?.try(&.map(&.as_s)) if parsed.as_a?
        return list.compact if list
      rescue
      end
      raw.split(",").map(&.strip).reject(&.empty?)
    end

    private def force_formula? : Bool
      true?(@params["force_formula"]?)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::HomebrewPlugin.new(config)
plugin.run
