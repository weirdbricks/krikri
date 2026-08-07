#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Selinux Plugin - Configure SELinux state and policy, matching
  # ansible.posix.selinux for the subset os_hardening uses.
  #
  # Parameters:
  #   state (optional): enforcing, permissive, or disabled
  #   policy (optional): targeted, minimum, mls, or a custom name
  #   check_mode: dry-run (predict, don't apply)
  #
  # Real ansible.posix.selinux enforces the running SELinux mode and
  # rewrites /etc/selinux/config so the mode survives reboot. On hosts where
  # SELinux is not compiled in / not active (no /etc/selinux/config, e.g.
  # stock Ubuntu), the module is effectively a no-op - it reports that
  # nothing needed changing rather than failing, which is how os_hardening
  # cleanly applies to both EL and Debian-family hosts. This mirrors that
  # deliberately.
  class SelinuxPlugin < BasePlugin
    property check_mode : Bool

    CONFIG_PATH = "/etc/selinux/config"

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = is_true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      state = @params["state"]?
      policy = @params["policy"]?

      valid_states = ["enforcing", "permissive", "disabled"]
      if state && !valid_states.includes?(state)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be one of: #{valid_states.join(", ")}"
        )
      end

      # No SELinux config on this host (SELinux absent / not installed).
      # Real module is a no-op here; report it so the task can't fail a
      # Debian/Ubuntu baseline.
      unless File.exists?(CONFIG_PATH)
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "SELinux is not installed (no #{CONFIG_PATH})"
        )
      end

      # Read current config: extract SELINUX= and SELINUXTYPE= lines.
      original = File.read(CONFIG_PATH)
      lines = original.lines

      current_state = extract(original, "SELINUX")
      current_policy = extract(original, "SELINUXTYPE")

      changed = false
      messages = [] of String

      if state && state != current_state
        messages << "state #{current_state.inspect} -> #{state}"
        changed = true
        if @check_mode
          # predict only
        else
          lines = lines.map { |line| replace_assignment(line, "SELINUX", state) }
        end
      end

      if policy && policy != current_policy
        messages << "policy #{current_policy.inspect} -> #{policy}"
        changed = true
        if @check_mode
          # predict only
        else
          lines = lines.map { |line| replace_assignment(line, "SELINUXTYPE", policy) }
        end
      end

      if changed && !@check_mode
        File.write(CONFIG_PATH, lines.join("\n"))
      end

      msg = messages.empty? ? "Nothing to do" : messages.join(", ")
      msg += " (check mode)" if @check_mode && changed

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg
      )
    end

    private def extract(content : String, key : String) : String
      content.each_line do |line|
        line = line.strip
        next if line.empty? || line.starts_with?("#")
        if line.starts_with?("#{key}=")
          return line.split("=", 2)[1].strip.gsub(/^"|"$/, "")
        end
      end
      ""
    end

    private def replace_assignment(line : String, key : String, value : String) : String
      # Rewrite an existing `key=value` assignment (skip comments).
      stripped = line.strip
      if stripped.starts_with?("#{key}=")
        indent = line[0, line.size - line.lstrip.size]
        "#{indent}#{key}=#{value}"
      else
        line
      end
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::SelinuxPlugin.new(config)
plugin.run
