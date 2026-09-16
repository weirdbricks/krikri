#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/selinux_config"

module Krikri
  # Selinux Plugin - Configure SELinux state and policy, matching
  # ansible.posix.selinux for the subset os_hardening uses.
  #
  # Parameters:
  #   state (REQUIRED): enforcing, permissive, or disabled
  #   policy (optional): targeted, minimum, mls, or a custom name -
  #     required by real Ansible whenever state is not "disabled"
  #   check_mode: dry-run (predict, don't apply)
  #
  # Real ansible.posix.selinux enforces the running SELinux mode and
  # rewrites /etc/selinux/config so the mode survives reboot. The
  # argument rules (state required, policy required unless
  # state=disabled, nonexistent policy rejected) live in
  # PluginHelpers::SelinuxConfig, which documents the ported order.
  class SelinuxPlugin < BasePlugin
    property? check_mode : Bool

    CONFIG_PATH = "/etc/selinux/config"

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
    end

    def execute : PluginResult
      state = @params["state"]?
      policy = @params["policy"]?

      if err = PluginHelpers::SelinuxConfig.state_validation_error(state)
        return PluginResult.new(changed: false, failed: true, msg: err)
      end
      state = state.not_nil!

      # Real ansible.posix.selinux ALWAYS fails when the config file is
      # missing - unconditionally, regardless of distro - confirmed
      # directly against the module's own source
      # (`if not os.path.isfile(configfile): module.fail_json(msg=
      # "Unable to find file {0}".format(configfile), details="Please
      # install SELinux-policy package, if this package is not
      # installed previously.")`). There is no "SELinux not compiled
      # in, treat as no-op" special case anywhere in it - this plugin
      # previously assumed one (to let os_hardening "cleanly apply" to
      # Debian-family hosts), which was simply wrong: found live via
      # buluma.selinux on a Rocky 9.6 host missing the SELinux-policy
      # package, where real Ansible failed with this exact message and
      # this plugin silently reported success instead.
      unless File.exists?(CONFIG_PATH)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unable to find file #{CONFIG_PATH}",
          details: "Please install SELinux-policy package, if this package is not installed previously."
        )
      end

      # Real's policy-required rule fires after the config-file check and
      # before any change computation - a state=enforcing call with no
      # policy: is a hard failure even when the state already matches.
      if PluginHelpers::SelinuxConfig.policy_required?(state, policy)
        return PluginResult.new(changed: false, failed: true, msg: "Policy is required if state is not 'disabled'")
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
        # Real does the policy-store existence check inside
        # set_config_policy - i.e. only on the non-check-mode write path
        # (check mode exits changed=true before reaching it).
        if @check_mode
          # predict only
        else
          if err = PluginHelpers::SelinuxConfig.policy_exists_error(policy)
            return PluginResult.new(changed: false, failed: true, msg: err)
          end
          lines = lines.map { |line| replace_assignment(line, "SELINUXTYPE", policy) }
        end
        messages << "policy #{current_policy.inspect} -> #{policy}"
        changed = true
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
plugin = Krikri::SelinuxPlugin.new(config)
plugin.run
