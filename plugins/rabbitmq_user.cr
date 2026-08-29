#!/usr/bin/env crystal
# community.rabbitmq.rabbitmq_user - manages RabbitMQ users via
# `rabbitmqctl`. Ported from community.rabbitmq's rabbitmq_user module
# (round 196: mrlesmithjr.rabbitmq uses it). Supports user add/delete,
# password changes, tag updates and vhost permission grants - the subset
# the corpus actually calls.
require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class RabbitmqUserPlugin < BasePlugin
    def execute : PluginResult
      user = @params["user"]?
      unless user
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: user")
      end
      state = @params["state"]? || "present"
      password = @params["password"]?
      tags = @params["tags"]?.try { |t| t.split(',').map(&.strip).reject(&.empty?) }
      perms = @params["permissions"]?

      list_out = remote_exec("rabbitmqctl list_users")
      if list_out[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to list RabbitMQ users: #{list_out[:stderr]}")
      end
      # user rows: "user\t[tags]"; the listing includes the header row
      existing = list_out[:stdout].lines.any? do |l|
        first = l.split(/[ \t]/).first?
        first == user
      end

      if state == "absent"
        return PluginResult.new(changed: false, failed: false, msg: "User #{user} does not exist") unless existing
        r = remote_exec("rabbitmqctl delete_user #{user}")
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to delete user #{user}: #{r[:stderr]}") if r[:exit_code] != 0
        return PluginResult.new(changed: true, failed: false, msg: "User #{user} deleted")
      end

      changed = false
      if existing
        if password
          r = remote_exec("rabbitmqctl change_password #{user} '#{password}'")
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to change password for #{user}: #{r[:stderr]}") if r[:exit_code] != 0
          changed = true
        end
      else
        r = remote_exec("rabbitmqctl add_user #{user} #{password ? "'#{password}'" : ""}".strip)
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to add user #{user}: #{r[:stderr]}") if r[:exit_code] != 0
        changed = true
      end

      if tags && !tags.empty?
        tags_json = "[" + tags.map { |t| "\"#{t}\"" }.join(",") + "]"
        r = remote_exec("rabbitmqctl set_user_tags #{user} #{tags_json}")
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to set tags for #{user}: #{r[:stderr]}") if r[:exit_code] != 0
        changed = true if !existing
      end

      # permissions: list of {vhost=, configure_privilege=, read_privilege=,
      # write_privilege=} dicts (the module's own shape); apply each
      if perms_json = perms
        begin
          arr = JSON.parse(perms_json).as_a?
          arr.try(&.each do |entry|
            h = entry.as_h
            vhost = h["vhost"]?.try(&.as_s) || "/"
            conf = h["configure_privilege"]?.try(&.as_s) || ".*"
            read = h["read_privilege"]?.try(&.as_s) || ".*"
            write = h["write_privilege"]?.try(&.as_s) || ".*"
            r = remote_exec("rabbitmqctl set_permissions -p #{vhost} #{user} '#{conf}' '#{read}' '#{write}'")
            return PluginResult.new(changed: false, failed: true,
              msg: "Failed to set permissions for #{user} on #{vhost}: #{r[:stderr]}") if r[:exit_code] != 0
            changed = true
          end)
        rescue ex
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to parse permissions: #{ex.message}")
        end
      end

      PluginResult.new(changed: changed, failed: false, msg: "User #{user} configured")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::RabbitmqUserPlugin.new(config)
plugin.run
