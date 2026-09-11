#!/usr/bin/env crystal
# community.general.easy_install - installs Python libraries via
# `easy_install`, optionally into a virtualenv. Ported from
# community.general's easy_install module (round 300033:
# cchurch.virtualenv uses it; previously unavailable -> rc=4
# "unavailable modules").
#
# Semantics matching the real module:
# - state present/latest (latest adds --upgrade); there is no absent -
#   easy_install can only install.
# - virtualenv: created with virtualenv_command (default virtualenv)
#   when its bin/activate is missing, --system-site-packages when
#   virtualenv_site_packages is set; easy_install is then resolved from
#   the venv's bin dir first.
# - installed probe: `easy_install --dry-run <name>` - "Downloading" in
#   the output means not installed (the real module's
#   _is_package_installed).
# - executable: explicit path/basename override (default easy_install).
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/easy_install"

module Krikri
  class EasyInstallPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "missing required argument: name") unless name

      state = @params["state"]? || "present"
      unless state == "present" || state == "latest"
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, latest, got #{state}")
      end
      virtualenv = @params["virtualenv"]?.presence
      site_packages = true?(@params["virtualenv_site_packages"]?)
      virtualenv_command = @params["virtualenv_command"]?.presence || "virtualenv"
      executable = @params["executable"]?.presence || "easy_install"

      out_parts = [] of String

      if virtualenv
        activate = PluginHelpers::EasyInstall.venv_activate_path(virtualenv)
        exists = remote_exec("test -f #{activate}")
        if exists[:exit_code] != 0
          venv_bin = remote_exec("command -v #{virtualenv_command}")
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to find required executable #{virtualenv_command} in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin") if venv_bin[:exit_code] != 0
          create = remote_exec(PluginHelpers::EasyInstall.venv_create_command(virtualenv_command, virtualenv, site_packages))
          out_parts << create[:stdout]
          return PluginResult.new(changed: false, failed: true,
            msg: create[:stderr]) if create[:exit_code] != 0
        end
      end

      easy_install = PluginHelpers::EasyInstall.resolve_executable(executable, virtualenv)
      found = remote_exec("command -v #{easy_install.split("/").last} || test -x #{easy_install}")
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to find required executable #{easy_install} in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin") if found[:exit_code] != 0

      arguments = [PluginHelpers::EasyInstall.state_arguments(state)]
      probe = remote_exec(PluginHelpers::EasyInstall.probe_command(easy_install, arguments, name))
      return PluginResult.new(changed: false, failed: true,
        msg: probe[:stderr]) if probe[:exit_code] != 0

      changed = false
      unless PluginHelpers::EasyInstall.installed?(probe[:stdout])
        install = remote_exec(PluginHelpers::EasyInstall.install_command(easy_install, arguments, name))
        out_parts << install[:stdout]
        return PluginResult.new(changed: false, failed: true,
          msg: install[:stderr]) if install[:exit_code] != 0
        changed = true
      end

      PluginResult.new(changed: changed, failed: false, msg: changed ? "Package installed" : "Package already installed",
        binary: easy_install, name: name, virtualenv: virtualenv.to_s)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::EasyInstallPlugin.new(config)
plugin.run
