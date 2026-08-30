#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Seboolean plugin - toggles an SELinux boolean via `getsebool`/
  # `setsebool`. Compatible with Ansible's ansible.posix.seboolean
  # (verified against real ansible-playbook on a Rocky 9.6 target with
  # SELinux genuinely enforcing).
  #
  # Real seboolean.py binds libselinux/libsemanage directly rather than
  # shelling out - this uses the equivalent CLI tools instead (matching
  # this codebase's general shell-out approach for SELinux/RPM tooling -
  # see selinux.cr/rpm_key.cr's own class docs for the same trade-off),
  # since `getsebool`/`setsebool` are the same underlying libsemanage
  # policy store the real module manipulates.
  #
  # Supported parameters:
  # - name: required.
  # - state: required. Boolean-ish string (true/false/yes/no/1/0/on/off).
  # - persistent: default false. Passes `-P` to `setsebool`, writing the
  #   change into the persistent policy store (survives a reboot) rather
  #   than only the running kernel's active value.
  # - ignore_selinux_state: default false. Skips the "SELinux enabled"
  #   pre-check (real module's own escape hatch for chrooted targets
  #   where the real runtime state can't be queried).
  class SebooleanPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: name") unless name

      state_param = @params["state"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: state") unless state_param
      desired_on = true?(state_param)

      persistent = true?(@params["persistent"]?)
      ignore_selinux_state = true?(@params["ignore_selinux_state"]?)

      unless ignore_selinux_state
        enforce = remote_exec("getenforce")
        if enforce[:exit_code] != 0 || enforce[:stdout].strip.downcase == "disabled"
          return PluginResult.new(changed: false, failed: true, msg: "SELinux is disabled on this host.")
        end
      end

      current = remote_exec("getsebool #{name}")
      unless current[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to determine current state for boolean #{name}")
      end

      # `getsebool <name>` prints "<name> --> on" / "<name> --> off".
      current_on = current[:stdout].strip.ends_with?("--> on")

      return PluginResult.new(changed: false, failed: false, msg: "") if current_on == desired_on

      value = desired_on ? "on" : "off"
      flag = persistent ? "-P " : ""
      result = remote_exec("setsebool #{flag}#{name} #{value}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to set boolean #{name} to #{value}: #{result[:stderr]}")
      end

      PluginResult.new(changed: true, failed: false, msg: "")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SebooleanPlugin.new(config)
plugin.run
