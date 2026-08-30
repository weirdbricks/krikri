#!/usr/bin/env crystal

# dpkg_selections module (ansible.builtin.dpkg_selections) - sets a
# package's dpkg selection state (hold/install/deinstall/purge) via the
# real `dpkg`/`dpkg-query` binaries, same approach real Ansible's own
# module takes (it shells out to dpkg --set-selections too, no python-apt
# binding).
#
# Parameters:
#   name (required): package name
#   selection (required): one of install, hold, deinstall, purge

require "json"
require "../src/krikri/base_plugin"

module Krikri
  class DpkgSelectionsPlugin < BasePlugin
    VALID_SELECTIONS = {"install", "hold", "deinstall", "purge"}

    def execute : PluginResult
      name = @params["name"]?
      selection = @params["selection"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: selection") unless selection

      unless VALID_SELECTIONS.includes?(selection)
        return PluginResult.new(changed: false, failed: true, msg: "selection must be one of #{VALID_SELECTIONS.join(", ")}, got '#{selection}'")
      end

      # Real Ansible's own module refuses to set a selection for a
      # package dpkg has never heard of ("Failed to find package 'tree'
      # to perform selection 'install'.", verified live against a real
      # Ubuntu host for a package that was never installed) - `dpkg
      # --set-selections` itself has no such guard (it happily records a
      # selection for an unknown package name, which then has no effect
      # until/unless that package is ever installed), so without this
      # check this plugin silently "succeeded" at a no-op real Ansible
      # treats as a hard error.
      known = remote_exec("dpkg-query -W #{shell_quote(name)} 2>/dev/null")
      if known[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to find package '#{name}' to perform selection '#{selection}'.")
      end

      current = remote_exec("dpkg --get-selections #{shell_quote(name)} 2>/dev/null")
      current_selection = current[:stdout].strip.split(/\s+/).last?

      if current_selection == selection
        return PluginResult.new(changed: false, failed: false, msg: "#{name} already set to #{selection}")
      end

      check_mode = true?(@params["check_mode"]?)
      return PluginResult.new(changed: true, failed: false, msg: "#{name} would be set to #{selection}") if check_mode

      result = remote_exec("echo #{shell_quote("#{name} #{selection}")} | dpkg --set-selections")
      return PluginResult.new(changed: false, failed: true, msg: "failed to set selection: #{result[:stderr].strip}") unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "#{name} set to #{selection}")
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DpkgSelectionsPlugin.new(config)
plugin.run
