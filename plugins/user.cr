#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/user_state"

module CrystalPlay
  # User plugin - manages a system account via getent/useradd/usermod/userdel
  # Compatible with (a subset of) Ansible's ansible.builtin.user module
  #
  # Parameters:
  #   name (required)
  #   state (optional): present (default) or absent
  #   uid, group (primary gid/group name), groups (supplementary, comma
  #     separated), shell, home, comment (optional)
  #   system (optional, default no): pass -r to useradd
  #   create_home (optional, default yes)
  #   remove (optional, default no): pass -r to userdel (also remove home dir)
  #
  # Password management is intentionally out of scope - setting/rotating
  # account passwords is security-sensitive enough that it deserves its own
  # careful design rather than a quick addition here.
  class UserPlugin < BasePlugin
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

    private def lookup(name : String) : PluginHelpers::UserState::User?
      result = remote_exec("getent passwd #{name}")
      return nil unless result[:exit_code] == 0
      PluginHelpers::UserState.parse(result[:stdout])
    end

    private def ensure_absent(name : String, current : PluginHelpers::UserState::User?, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "User already absent") unless current

      return PluginResult.new(changed: true, failed: false, msg: "Would remove user (check mode)") if check_mode

      args = PluginHelpers::UserState.userdel_args(name, is_true?(@params["remove"]?))
      result = remote_exec("userdel #{args.join(" ")}")
      return command_failure("remove user", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "User removed")
    end

    private def ensure_present(name : String, current : PluginHelpers::UserState::User?, check_mode : Bool) : PluginResult
      current ? modify(name, current, check_mode) : create(name, check_mode)
    end

    private def create(name : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: true, failed: false, msg: "Would create user (check mode)") if check_mode

      create_home = @params["create_home"]?.nil? || is_true?(@params["create_home"]?)
      args = PluginHelpers::UserState.useradd_args(
        name,
        @params["uid"]?,
        @params["group"]?,
        @params["groups"]?,
        @params["shell"]?,
        @params["home"]?,
        @params["comment"]?,
        is_true?(@params["system"]?),
        create_home
      )

      result = remote_exec("useradd #{args.join(" ")}")
      return command_failure("create user", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "User created")
    end

    private def modify(name : String, current : PluginHelpers::UserState::User, check_mode : Bool) : PluginResult
      flags = PluginHelpers::UserState.usermod_flags(
        current,
        @params["uid"]?,
        @params["group"]?,
        @params["shell"]?,
        @params["home"]?,
        @params["comment"]?
      )
      return PluginResult.new(changed: false, failed: false, msg: "User already up to date") if flags.empty?

      return PluginResult.new(changed: true, failed: false, msg: "Would modify user (check mode)") if check_mode

      result = remote_exec("usermod #{flags.join(" ")} #{name}")
      return command_failure("modify user", result) unless result[:exit_code] == 0

      PluginResult.new(changed: true, failed: false, msg: "User modified")
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
plugin = CrystalPlay::UserPlugin.new(config)
plugin.run
