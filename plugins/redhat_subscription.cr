#!/usr/bin/env crystal
# community.general.redhat_subscription - manages Red Hat subscription
# registration via `subscription-manager`. Ported subset of
# community.general's redhat_subscription module (round 196:
# linux-system-roles.rhc calls it; previously unavailable → rc=4
# "unavailable modules" where real ansible failed at its own
# required_one_of validation with
# "state is present but any of the following are missing: username,
# activationkey, token" - observed live on Rocky 9.6).
#
# Supported here: state (present/absent), username/password,
# activationkey, org_id, token, force. The required_one_of validation
# fires BEFORE any binary check, exactly like the real module's
# AnsibleModule argument validation.
require "json"
require "../src/krikri/base_plugin"

module Krikri
  class RedhatSubscriptionPlugin < BasePlugin
    def execute : PluginResult
      state = @params["state"]? || "present"

      if state == "present" && !credential_present?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is present but any of the following are missing: username, activationkey, token")
      end

      bin = "subscription-manager"
      check = remote_exec("command -v #{bin}")
      if check[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to find required executable #{bin} in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
      end

      # already registered?
      identity = remote_exec("#{bin} identity")
      registered = identity[:exit_code] == 0

      return handle_absent(bin) if state == "absent"
      return PluginResult.new(changed: false, failed: false, msg: "System already registered") if registered

      r = remote_exec(build_register_command(bin))
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to register: #{r[:stderr] || r[:stdout]}") if r[:exit_code] != 0
      PluginResult.new(changed: true, failed: false, msg: "System registered")
    end

    private def credential_present? : Bool
      username = @params["username"]?
      activationkey = @params["activationkey"]?
      token = @params["token"]?
      !username.to_s.empty? || !activationkey.to_s.empty? || !token.to_s.empty?
    end

    private def handle_absent(bin : String) : PluginResult
      identity = remote_exec("#{bin} identity")
      registered = identity[:exit_code] == 0
      return PluginResult.new(changed: false, failed: false, msg: "System is not registered") unless registered
      r = remote_exec("#{bin} unregister")
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to unregister: #{r[:stderr]}") if r[:exit_code] != 0
      PluginResult.new(changed: true, failed: false, msg: "System unregistered")
    end

    private def build_register_command(bin : String) : String
      username = @params["username"]?
      activationkey = @params["activationkey"]?
      token = @params["token"]?

      cmd = "#{bin} register --auto-attach"
      cmd += activation_args(activationkey, token, username) if activationkey || token || username
      cmd += " --force" if @params["force"]?
      cmd
    end

    private def activation_args(activationkey : String?, token : String?, username : String?) : String
      args = ""
      if activationkey && !activationkey.to_s.empty?
        args += " --activationkey=#{activationkey}"
        args += " --org=#{@params["org_id"]}" if @params["org_id"]?
      elsif token && !token.to_s.empty?
        args += " --token=#{token}"
      else
        args += " --username=#{username} --password='#{@params["password"]?}'"
      end
      args
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::RedhatSubscriptionPlugin.new(config)
plugin.run
