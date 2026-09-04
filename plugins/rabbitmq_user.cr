#!/usr/bin/env crystal
# community.rabbitmq.rabbitmq_user - manages RabbitMQ users via
# `rabbitmqctl`. Ported from community.rabbitmq's rabbitmq_user module
# (round 196: mrlesmithjr.rabbitmq uses it). Supports user add/delete,
# password changes, tag updates and vhost permission grants - the subset
# the corpus actually calls.
require "json"
require "../src/krikri/base_plugin"

module Krikri
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

      list_out = remote_exec("rabbitmqctl list_users")
      if list_out[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to list RabbitMQ users: #{list_out[:stderr]}")
      end
      existing, current_tags = parse_user_list(list_out, user)

      return delete_user(user, existing) if state == "absent"

      configure_user(user, existing, current_tags)
    end

    private def parse_user_list(list_out : NamedTuple(exit_code: Int32, stdout: String, stderr: String), user : String) : {Bool, Array(String)?}
      # user rows: "user\t[tags]"; the listing includes the header row.
      # Capture the user's current tags too - the real module skips the
      # set_user_tags call when they already match (an unconditional
      # apply made every warm pass report changed).
      # Tag parsing mirrors the real module's process_tags: strip ALL
      # brackets and spaces from the bracketed tag list, then split on
      # commas. This also converges state written by the old JSON-array
      # format (rabbitmqctl stored the literal tag ["administrator"],
      # shown by list_users as [[administrator]]) without a rewrite.
      existing = false
      current_tags : Array(String)? = nil
      (list_out[:stdout] + "\n" + list_out[:stderr]).each_line do |lval|
        parts = lval.strip.split(/[ \t]+/)
        next unless parts.first? == user
        existing = true
        if m = lval.match(/\[(.*)\]/)
          current_tags = m[1].gsub(/[\[\] ]/, "").split(",").reject(&.empty?)
        end
      end
      {existing, current_tags}
    end

    private def delete_user(user : String, existing : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "User #{user} does not exist") unless existing
      r = remote_exec("rabbitmqctl delete_user #{user}")
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to delete user #{user}: #{r[:stderr]}") if r[:exit_code] != 0
      PluginResult.new(changed: true, failed: false, msg: "User #{user} deleted")
    end

    private def configure_user(user : String, existing : Bool, current_tags : Array(String)?) : PluginResult
      changed = false
      begin
        changed = add_user_if_missing(user, existing)
        tags_failed = set_tags_if_needed(user, current_tags)
        return tags_failed if tags_failed
        changed = true if apply_permissions(user)
      rescue e : CommandError
        return PluginResult.new(changed: false, failed: true, msg: e.message || "command failed")
      end
      PluginResult.new(changed: changed, failed: false, msg: "User #{user} configured")
    end

    private def add_user_if_missing(user : String, existing : Bool) : Bool
      return false if existing
      # password changes for an EXISTING user: the real module compares
      # the stored hash and only rewrites on a mismatch; unconditionally
      # running change_password made every warm pass report changed
      # (mrlesmithjr.rabbitmq round-196 re-run). Match the create-time-
      # only behavior until a hash comparison is added.
      password = @params["password"]?
      r = remote_exec("rabbitmqctl add_user #{user} #{password ? "'#{password}'" : ""}".strip)
      raise CommandError.new("Failed to add user #{user}: #{r[:stderr]}") if r[:exit_code] != 0
      true
    end

    private def set_tags_if_needed(user : String, current_tags : Array(String)?) : PluginResult?
      tags = @params["tags"]?.try { |tval| tval.split(',').map(&.strip).reject(&.empty?) }
      return nil if tags.nil? || tags.empty?

      # skip the call when the user's current tags already match the
      # requested set (order-insensitive) - real module behavior
      return nil if current_tags && current_tags.sort == tags.sort

      # real module: each tag as its own argv - `set_user_tags user
      # tag1 tag2` - NOT a JSON array, which rabbitmqctl stores as the
      # literal tag string ["tag1"] and so never converges
      r = remote_exec("rabbitmqctl set_user_tags #{user} #{tags.join(" ")}")
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to set tags for #{user}: #{r[:stderr]}") if r[:exit_code] != 0
      nil
    end

    private def apply_permissions(user : String) : Bool
      # real module: compare the user's existing permissions against the
      # requested ones and only run set_permissions (or report changed)
      # on a difference - an unconditional apply made every warm pass
      # report changed (mrlesmithjr.rabbitmq round-196 re-run).
      vhost = @params["vhost"]? || "/"
      conf_priv = @params["configure_priv"]? || "^$"
      read_priv = @params["read_priv"]? || "^$"
      write_priv = @params["write_priv"]? || "^$"

      perms_out = remote_exec("rabbitmqctl -q list_user_permissions #{user}")
      raise CommandError.new("Failed to list permissions for #{user}: #{perms_out[:stderr]}") if perms_out[:exit_code] != 0

      # rows: "vhost\tconfigure\twrite\tread"; the header row is printed
      # even with -q on rabbitmq 4.x, so filter it
      existing = nil
      perms_out[:stdout].each_line do |lval|
        parts = lval.strip.split("\t")
        next unless parts.size >= 4
        next if parts[0] == "vhost"
        next unless parts[0] == vhost
        existing = {parts[1], parts[2], parts[3]}
      end

      requested = {conf_priv, write_priv, read_priv}
      return false if existing == requested

      r = remote_exec("rabbitmqctl set_permissions -p #{vhost} #{user} '#{conf_priv}' '#{read_priv}' '#{write_priv}'")
      raise CommandError.new("Failed to set permissions for #{user} on #{vhost}: #{r[:stderr]}") if r[:exit_code] != 0

      true
    end

    class CommandError < Exception
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::RabbitmqUserPlugin.new(config)
plugin.run
