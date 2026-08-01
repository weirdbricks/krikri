#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/group_state"

module CrystalPlay
  # Group plugin - manages a system group via getent/groupadd/groupmod/groupdel
  # Compatible with (a subset of) Ansible's ansible.builtin.group module
  #
  # Parameters:
  #   name (required)
  #   state (optional): present (default) or absent
  #   gid (optional)
  #   system (optional, default no): pass -r to groupadd for a system group
  class GroupPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)
      current = lookup(name)

      if state == "absent"
        ensure_absent(name, current, check_mode)
      else
        ensure_present(name, current, check_mode)
      end
    end

    private def lookup(name : String) : PluginHelpers::GroupState::Group?
      result = remote_exec("getent group #{name}")
      return nil unless result[:exit_code] == 0
      PluginHelpers::GroupState.parse(result[:stdout])
    end

    private def ensure_absent(name : String, current : PluginHelpers::GroupState::Group?, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "Group already absent") unless current

      return PluginResult.new(changed: true, failed: false, msg: "Would remove group (check mode)") if check_mode

      result = remote_exec("groupdel #{name}")
      return command_failure("remove group", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "Group removed")
    end

    private def ensure_present(name : String, current : PluginHelpers::GroupState::Group?, check_mode : Bool) : PluginResult
      gid = @params["gid"]?
      system = is_true?(@params["system"]?)

      unless current
        return PluginResult.new(changed: true, failed: false, msg: "Would create group (check mode)") if check_mode

        args = PluginHelpers::GroupState.groupadd_args(name, gid, system)
        result = remote_exec("groupadd #{args.join(" ")}")
        return command_failure("create group", result) unless result[:exit_code] == 0

        return PluginResult.new(changed: true, failed: false, msg: "Group created")
      end

      flags = PluginHelpers::GroupState.groupmod_flags(current, gid)
      return PluginResult.new(changed: false, failed: false, msg: "Group already up to date") if flags.empty?

      return PluginResult.new(changed: true, failed: false, msg: "Would modify group (check mode)") if check_mode

      result = remote_exec("groupmod #{flags.join(" ")} #{name}")
      return command_failure("modify group", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "Group modified")
    end

    private def command_failure(action : String, result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Failed to #{action}: #{result[:stderr].empty? ? result[:stdout] : result[:stderr]}")
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::GroupPlugin.new(config)
plugin.run
