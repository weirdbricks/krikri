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
      # community.rabbitmq.rabbitmq_user's own argspec: `name` (the user),
      # `vhost` (default "/"), `configure_priv`/`read_priv`/`write_priv`
      # (default "."), `tags`, `password`, `state`. mrlesmithjr.rabbitmq
      # calls it exactly that way.
      user = @params["name"]?
      unless user
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end
      state = @params["state"]? || "present"
      password = @params["password"]?
      vhost = @params["vhost"]? || "/"
      tags = @params["tags"]?.try { |t| t.split(',').map(&.strip).reject(&.empty?) }
      conf_priv = @params["configure_priv"]? || ".*"
      read_priv = @params["read_priv"]? || ".*"
      write_priv = @params["write_priv"]? || ".*"

      list_out = remote_exec("rabbitmqctl list_users")
      if list_out[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to list RabbitMQ users: #{list_out[:stderr]}")
      end
      # user rows: "user\t[tags]"; the listing includes the header row.
      # Capture the user's current tags too - the real module skips the
      # set_user_tags call when they already match (an unconditional
      # apply made every warm pass report changed).
      existing = false
      current_tags : Array(String)? = nil
      list_text = list_out[:stdout] + "\n" + list_out[:stderr]
      list_text.each_line do |l|
        parts = l.strip.split(/[ \t]+/)
        next unless parts.first? == user
        existing = true
        if m = l.match(/\[(.*)\]/)
          current_tags = m[1].split(",").map(&.strip)
        end
      end

      if state == "absent"
        return PluginResult.new(changed: false, failed: false, msg: "User #{user} does not exist") unless existing
        r = remote_exec("rabbitmqctl delete_user #{user}")
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to delete user #{user}: #{r[:stderr]}") if r[:exit_code] != 0
        return PluginResult.new(changed: true, failed: false, msg: "User #{user} deleted")
      end

      changed = false
      unless existing
        r = remote_exec("rabbitmqctl add_user #{user} #{password ? "'#{password}'" : ""}".strip)
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to add user #{user}: #{r[:stderr]}") if r[:exit_code] != 0
        changed = true
      end
      # password changes for an EXISTING user: the real module compares
      # the stored hash and only rewrites on a mismatch; unconditionally
      # running change_password made every warm pass report changed
      # (mrlesmithjr.rabbitmq round-196 re-run). Match the create-time-
      # only behavior until a hash comparison is added.

      if tags && !tags.empty?
        # skip the call when the user's current tags already match the
        # requested set (order-insensitive) - real module behavior
        unless current_tags && current_tags.sort == tags.sort
          tags_json = "[" + tags.map { |t| "\"#{t}\"" }.join(",") + "]"
          r = remote_exec("rabbitmqctl set_user_tags #{user} #{tags_json}")
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to set tags for #{user}: #{r[:stderr]}") if r[:exit_code] != 0
          changed = true
        end
      end

      # the module always applies set_permissions (its own "always runs"
      # behavior); idempotency comes from rabbitmqctl being a no-op when
      # the privileges already match
      r = remote_exec("rabbitmqctl set_permissions -p #{vhost} #{user} '#{conf_priv}' '#{read_priv}' '#{write_priv}'")
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to set permissions for #{user} on #{vhost}: #{r[:stderr]}") if r[:exit_code] != 0

      PluginResult.new(changed: changed, failed: false, msg: "User #{user} configured")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::RabbitmqUserPlugin.new(config)
plugin.run
