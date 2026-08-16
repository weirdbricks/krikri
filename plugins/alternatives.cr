#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Alternatives plugin - manages symlinks via `update-alternatives`.
  # Compatible with (a subset of) community.general.alternatives.
  #
  # Entirely unimplemented before - robertdebock.alternatives' own
  # "Configure alternatives" task (community.general.alternatives)
  # silently dropped while real Ansible actually ran update-alternatives.
  #
  # Debian/Ubuntu (`update-alternatives`) only - `family:` is RHEL-only
  # and not supported (no RHEL host available to verify against).
  class AlternativesPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "name is required") unless name

      path = @params["path"]?
      link = @params["link"]?
      priority_param = @params["priority"]?.try(&.to_i)
      state = @params["state"]? || "selected"
      subcommands = @params["subcommands"]?.try { |s| Array(JSON::Any).from_json(s) }

      current_mode, current_path, current_link, current_alternatives = parse_display(name)

      mode_present = ["present", "selected", "auto"].includes?(state)
      changed = false
      messages = [] of String

      if mode_present
        effective_link = link || current_link
        if path && (!current_alternatives.has_key?(path) || (priority_param && current_alternatives[path][:priority] != priority_param))
          unless effective_link
            return PluginResult.new(changed: false, failed: true, msg: "Needed to install the alternative, but unable to do so as we are missing the link")
          end
          priority = priority_param || current_alternatives[path]?.try(&.[:priority]) || 50
          cmd = ["update-alternatives", "--install", effective_link, name, path, priority.to_s]
          if subcommands
            subcommands.each do |s|
              cmd += ["--slave", s["link"].as_s, s["name"].as_s, s["path"].as_s]
            end
          end
          remote_exec(cmd.map { |c| shell_quote(c) }.join(' '))
          changed = true
          messages << "Install alternative '#{path}' for '#{name}'."
        end

        is_same_path = path && current_path == path
        if state == "selected" && path && !is_same_path
          remote_exec("update-alternatives --set #{shell_quote(name)} #{shell_quote(path)}")
          changed = true
          messages << "Set alternative '#{path}' for '#{name}'."
        end

        if state == "auto" && current_mode == "manual"
          remote_exec("update-alternatives --auto #{shell_quote(name)}")
          changed = true
          messages << "Set alternative to auto for '#{name}'."
        end
      else
        if path && current_alternatives.has_key?(path)
          remote_exec("update-alternatives --remove #{shell_quote(name)} #{shell_quote(path)}")
          changed = true
          messages << "Remove alternative '#{path}' from '#{name}'."
        end
      end

      PluginResult.new(changed: changed, failed: false, msg: messages.join(' '))
    end

    private def parse_display(name : String)
      result = remote_exec("update-alternatives --display #{shell_quote(name)}")
      current_alternatives = {} of String => NamedTuple(priority: Int32)
      return {nil, nil, nil, current_alternatives} unless result[:exit_code] == 0

      output = result[:stdout]
      current_mode = nil
      if m = output.match(/\s-\s(?:status\sis\s)?(\w*)(?:\smode|[^\n])$/m)
        current_mode = m[1]
      end

      current_path = nil
      if m = output.match(/^\s*link currently points to ([^\n]*)$/m)
        current_path = m[1].strip
      end

      current_link = nil
      if m = output.match(/^\s*link \w+ is ([^\n]*)$/m)
        current_link = m[1].strip
      end

      output.scan(/^(\/\S*)\s-\s(?:family\s(\S+)\s)?priority\s(\d+)/m) do |m|
        current_alternatives[m[1]] = {priority: m[3].to_i}
      end

      {current_mode, current_path, current_link, current_alternatives}
    end

    private def shell_quote(s : String) : String
      "'" + s.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::AlternativesPlugin.new(config)
plugin.run
