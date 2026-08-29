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
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class RedhatSubscriptionPlugin < BasePlugin
    def execute : PluginResult
      state = @params["state"]? || "present"

      username = @params["username"]?
      activationkey = @params["activationkey"]?
      token = @params["token"]?

      if state == "present"
        has_cred = !username.to_s.empty? || !activationkey.to_s.empty? || !token.to_s.empty?
        unless has_cred
          return PluginResult.new(changed: false, failed: true,
            msg: "state is present but any of the following are missing: username, activationkey, token")
        end
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

      if state == "absent"
        return PluginResult.new(changed: false, failed: false, msg: "System is not registered") unless registered
        r = remote_exec("#{bin} unregister")
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to unregister: #{r[:stderr]}") if r[:exit_code] != 0
        return PluginResult.new(changed: true, failed: false, msg: "System unregistered")
      end

      if registered
        return PluginResult.new(changed: false, failed: false, msg: "System already registered")
      end

      cmd = "#{bin} register --auto-attach"
      if activationkey && !activationkey.to_s.empty?
        cmd += " --activationkey=#{activationkey}"
        if org_id = @params["org_id"]?
          cmd += " --org=#{org_id}"
        end
      elsif token && !token.to_s.empty?
        cmd += " --token=#{token}"
      else
        cmd += " --username=#{username} --password='#{@params["password"]?}'"
      end
      if @params["force"]?
        cmd += " --force"
      end

      r = remote_exec(cmd)
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to register: #{r[:stderr] || r[:stdout]}") if r[:exit_code] != 0
      PluginResult.new(changed: true, failed: false, msg: "System registered")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::RedhatSubscriptionPlugin.new(config)
plugin.run
