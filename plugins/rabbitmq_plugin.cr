#!/usr/bin/env crystal
# community.rabbitmq.rabbitmq_plugin - manages RabbitMQ plugin state via
# `rabbitmq-plugins`. Ported from community.rabbitmq's rabbitmq_plugin
# module (round 196: mrlesmithjr.rabbitmq uses it; previously unavailable
# → rc=4 "unavailable modules" where real ansible rc=0'd).
#
# Idempotency: real module checks `rabbitmq-plugins list -E -m` (all
# enabled plugins, minimal output - bare names, one per line) for the
# plugin's name as an exact line match before doing anything.
require "json"
require "../src/krikri/base_plugin"

module Krikri
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

      bin = plugin_bin
      # real module: `rabbitmq-plugins list -E -m` - ALL enabled plugins
      # (explicit + implicit), minimal output (bare names, one per line),
      # membership checked as an exact line match. The older `list -e`
      # whole-text grep worked but the changed flag below never consulted
      # it, so every warm pass reported changed.
      listing = remote_exec("#{bin} list -E -m")
      if listing[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to list RabbitMQ plugins: #{listing[:stderr]}")
      end
      enabled_lines = enabled_plugin_lines(listing)

      enabled = [] of String
      disabled = [] of String
      error = state == "enabled" ? apply_enabled_state(bin, plugins, enabled_lines, enabled, disabled) : apply_disabled_state(bin, plugins, enabled_lines, disabled)
      return error if error

      # changed only reflects what actually ran - hardcoding true here was
      # the warm-run bug: apply-nothing fell through to changed=true
      # (mrlesmithjr.rabbitmq re-run, warm changed=2 vs real changed=0)
      PluginResult.new(changed: !enabled.empty? || !disabled.empty?, failed: false,
        msg: build_msg(enabled, disabled))
    end

    private def apply_enabled_state(bin : String, plugins : Array(String), enabled_lines : Array(String), enabled : Array(String), disabled : Array(String)) : PluginResult?
      unless new_only?
        # real module (state=enabled, new_only=false) disables every
        # enabled plugin not in the requested names. Header lines
        # ("Listing plugins with pattern ...") contain spaces and are
        # skipped the same way the real module skips them.
        enabled_lines.each do |line|
          next if line.includes?(" ")
          next if plugins.includes?(line)
          r = remote_exec("#{bin} disable #{line}")
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to disable plugin #{line}: #{r[:stderr]}") if r[:exit_code] != 0
          disabled << line
        end
      end
      plugins.each do |plugin|
        next if enabled_lines.includes?(plugin)
        r = remote_exec("#{bin} enable #{plugin}")
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to enable plugin #{plugin}: #{r[:stderr]}") if r[:exit_code] != 0
        enabled << plugin
      end
      nil
    end

    private def apply_disabled_state(bin : String, plugins : Array(String), enabled_lines : Array(String), disabled : Array(String)) : PluginResult?
      enabled_lines.each do |line|
        next unless plugins.includes?(line)
        r = remote_exec("#{bin} disable #{line}")
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to disable plugin #{line}: #{r[:stderr]}") if r[:exit_code] != 0
        disabled << line
      end
      nil
    end

    private def new_only? : Bool
      as_bool(@params["new_only"]?)
    end

    private def as_bool(value) : Bool
      case value
      when Bool   then value
      when String then value == "true" || value == "yes"
      else             false
      end
    end

    private def build_msg(enabled : Array(String), disabled : Array(String)) : String
      parts = [] of String
      parts << "Plugins enabled: #{enabled.join(", ")}" unless enabled.empty?
      parts << "Plugins disabled: #{disabled.join(", ")}" unless disabled.empty?
      parts.empty? ? "Plugins already in desired state" : parts.join("; ")
    end

    private def plugin_bin : String
      prefix = @params["prefix"]?
      new_basedir = @params["new_basedir"]?
      bin = prefix ? "#{prefix}/usr/lib/rabbitmq/bin/rabbitmq-plugins" : "rabbitmq-plugins"
      bin = "#{new_basedir}/rabbitmq-plugins" if new_basedir
      bin
    end

    private def enabled_plugin_lines(listing : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : Array(String)
      # real get_all(): collect output lines until the first empty line.
      # With -m the plugin rows are bare names; banner lines (ANSI on some
      # versions) contain spaces and never equal a requested name.
      (listing[:stdout].gsub(/\e\[[0-9;]*m/, "")).each_line
        .take_while { |line| !line.strip.empty? }
        .map(&.strip)
        .reject(&.empty?)
        .to_a
    end
  end
end

if ARGV.size == 1 && ARGV[0] == "--self-test"
  # no-op hook for compile checks
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::RabbitmqPluginPlugin.new(config)
plugin.run
