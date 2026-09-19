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
  # Argument validation runs BEFORE any SELinux call, matching real
  # AnsibleModule's argument_spec order of operations:
  # - name (str) and state (bool) are required; both missing fail in one
  #   message ("missing required arguments: name, state"), matching real
  #   spec-order listing.
  # - state, persistent, and ignore_selinux_state are bool-typed: only
  #   Ansible's BOOLEANS set (y/yes/on/1/true and n/no/off/0/false, case
  #   insensitive) is accepted; anything else fails the task instead of
  #   silently defaulting.
  #
  # Disabled-host behavior mirrors the real module's flow exactly: the
  # enabled-check (`get_runtime_status`) only runs when
  # ignore_selinux_state is false, and the non-persistent branch is
  # guarded by `selinux.is_selinux_enabled()` - so with
  # ignore_selinux_state: true on a SELinux-less host, a non-persistent
  # seboolean is a no-op SUCCESS (changed=False), not a failure. The
  # persistent branch runs regardless of enabled state in real too (it
  # talks to the semanage policy store directly), so it still fails here
  # when there is no store, just via a different mechanism.
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
      missing = ["name", "state"].select { |arg| @params[arg]?.nil? }
      unless missing.empty?
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: #{missing.join(", ")}")
      end
      name = @params["name"]
      state_param = @params["state"]

      desired_on = parse_bool(state_param)
      return bool_conversion_failure("state") unless desired_on.is_a?(Bool)

      persistent = parse_persistent
      return persistent if persistent.is_a?(PluginResult)

      ignore_selinux_state = parse_ignore_selinux_state
      return ignore_selinux_state if ignore_selinux_state.is_a?(PluginResult)

      unless ignore_selinux_state
        return PluginResult.new(changed: false, failed: true, msg: "SELinux is disabled on this host.") unless selinux_enabled?
      end

      result = PluginResult.new(changed: false, failed: false, msg: "")
      result.extra["name"] = JSON.parse(name.to_json)
      result.extra["persistent"] = JSON.parse(persistent.to_json)
      result.extra["state"] = JSON.parse(desired_on.to_json)

      # Real's persistent branch talks to the semanage policy store
      # regardless of the running kernel state; the non-persistent
      # branch is guarded by is_selinux_enabled() - a disabled host is
      # a no-op success there, matching real.
      unless persistent
        return result unless selinux_enabled?
      end
      set_boolean(name, desired_on, persistent, result)
    end

    private def set_boolean(name : String, desired_on : Bool, persistent : Bool, result : PluginResult) : PluginResult
      current = remote_exec("getsebool #{name}")
      unless current[:exit_code] == 0
        result.failed = true
        result.msg = "Failed to determine current state for boolean #{name}"
        return result
      end

      # `getsebool <name>` prints "<name> --> on" / "<name> --> off".
      current_on = current[:stdout].strip.ends_with?("--> on")

      return result if current_on == desired_on

      value = desired_on ? "on" : "off"
      flag = persistent ? "-P " : ""
      set_result = remote_exec("setsebool #{flag}#{name} #{value}")
      unless set_result[:exit_code] == 0
        result.failed = true
        result.msg = "Failed to set boolean #{name} to #{value}: #{set_result[:stderr]}"
        return result
      end

      result.changed = true
      result
    end

    # Real's enabled check is libselinux's is_selinux_enabled(); the
    # closest CLI proxy is whether `getenforce` runs and reports
    # something other than Disabled.
    private def selinux_enabled? : Bool
      enforce = remote_exec("getenforce")
      enforce[:exit_code] == 0 && enforce[:stdout].strip.downcase != "disabled"
    end

    private def parse_persistent : Bool | PluginResult
      if value = @params["persistent"]?
        persistent = parse_bool(value)
        return bool_conversion_failure("persistent") unless persistent.is_a?(Bool)
        persistent
      else
        false
      end
    end

    private def parse_ignore_selinux_state : Bool | PluginResult
      if value = @params["ignore_selinux_state"]?
        parsed = parse_bool(value)
        return bool_conversion_failure("ignore_selinux_state") unless parsed.is_a?(Bool)
        parsed
      else
        false
      end
    end

    # Ansible's BOOLEANS set, case-insensitive; anything else is a
    # validation failure, never a silent default.
    private def parse_bool(value : String) : Bool?
      lowered = value.downcase
      return true if ["y", "yes", "on", "1", "true"].includes?(lowered)
      return false if ["n", "no", "off", "0", "false"].includes?(lowered)
      nil
    end

    private def bool_conversion_failure(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "argument '#{name}' of type bool could not be converted to a bool")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SebooleanPlugin.new(config)
plugin.run
