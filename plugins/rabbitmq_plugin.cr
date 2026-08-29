#!/usr/bin/env crystal
# community.rabbitmq.rabbitmq_plugin - manages RabbitMQ plugin state via
# `rabbitmq-plugins`. Ported from community.rabbitmq's rabbitmq_plugin
# module (round 196: mrlesmithjr.rabbitmq uses it; previously unavailable
# → rc=4 "unavailable modules" where real ansible rc=0'd).
#
# Idempotency: real module checks `rabbitmq-plugins list -e` (the list of
# ENABLED plugins, one per line, with a trailing marker comment) for the
# plugin's short name before doing anything.
require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class RabbitmqPluginPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end
      # the module accepts a list (YAML) or a comma-separated string
      plugins = name.split(",").map(&.strip).reject(&.empty?)
      state = @params["state"]? || "enabled"
      unless state == "enabled" || state == "disabled"
        return PluginResult.new(changed: false, failed: true, msg: "state must be enabled or disabled")
      end

      prefix = @params["prefix"]?
      new_basedir = @params["new_basedir"]?
      bin = prefix ? "#{prefix}/usr/lib/rabbitmq/bin/rabbitmq-plugins" : "rabbitmq-plugins"
      bin = "#{new_basedir}/rabbitmq-plugins" if new_basedir

      enabled_out = remote_exec("#{bin} list -e")
      if enabled_out[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to list RabbitMQ plugins: #{enabled_out[:stderr]}")
      end
      # rabbitmq-plugins list -e output lines look like
      # "E* rabbitmq_management 4.x" / "e* rabbitmq_foo ..." - the enabled
      # marker prefix and indentation vary by version, so match the
      # plugin name as a whole word anywhere in the output rather than
      # requiring it to be the first token (the strict first-token parse
      # never matched, so every warm pass re-ran the enable command and
      # reported changed - mrlesmithjr.rabbitmq, round 196 re-run).
      # ANSI color codes (rabbitmq-plugins colorizes its listing on some
      # versions) would break name matching - strip them. list -e only
      # lists ENABLED plugins, so any word-boundary occurrence of the
      # plugin name means enabled.
      enabled_text = (enabled_out[:stdout] + "\n" + enabled_out[:stderr])
        .gsub(/\e\[[0-9;]*m/, "")

      changed = false
      plugins.each do |plugin|
        is_enabled = enabled_text.match(/\b#{Regex.escape(plugin)}\b/) != nil
        if state == "enabled" && !is_enabled
          r = remote_exec("#{bin} enable #{plugin}")
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to enable plugin #{plugin}: #{r[:stderr]}") if r[:exit_code] != 0
          changed = true
        elsif state == "disabled" && is_enabled
          r = remote_exec("#{bin} disable #{plugin}")
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to disable plugin #{plugin}: #{r[:stderr]}") if r[:exit_code] != 0
          changed = true
        end
      end

      PluginResult.new(changed: changed, failed: false,
        msg: state == "enabled" ? "Plugins enabled: #{plugins.join(", ")}" : "Plugins disabled: #{plugins.join(", ")}")
    end
  end
end

if ARGV.size == 1 && ARGV[0] == "--self-test"
  # no-op hook for compile checks
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::RabbitmqPluginPlugin.new(config)
plugin.run
