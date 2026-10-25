#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/python_lib_gate"
require "../src/krikri/plugin_helpers/selinux_config"

module Krikri
  # Selinux Plugin - Configure SELinux state and policy, matching
  # ansible.posix.selinux for the subset os_hardening uses.
  #
  # Parameters:
  #   state (REQUIRED): enforcing, permissive, or disabled
  #   policy (optional): targeted, minimum, mls, or a custom name -
  #     required by Ansible whenever state is not "disabled"
  #   check_mode: dry-run (predict, don't apply)
  #
  # Ansible.posix.selinux enforces the running SELinux mode and
  # rewrites /etc/selinux/config so the mode survives reboot. The
  # argument rules (state required, policy required unless
  # state=disabled, nonexistent policy rejected) live in
  # PluginHelpers::SelinuxConfig, which documents the ported order.
  # Runtime-state handling (issue #340): selinux.py:302-324's
  # runtime-disabled branch - a requested state with the runtime off can
  # only reach the kernel on the next boot, so it warns and exits
  # reboot_required=true, and `reboot_required` (boolean, false when no
  # reboot is pending) rides every exit_json.
  class SelinuxPlugin < BasePlugin
    property? check_mode : Bool

    CONFIG_PATH  = "/etc/selinux/config"
    ENFORCE_PATH = "/sys/fs/selinux/enforce"

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
    end

    def execute : PluginResult
      state = @params["state"]?
      policy = @params["policy"]?

      # Probe paths overridable solely so the regression test can point
      # them at spec scratch files - sandboxes without /etc/selinux/config
      # or /sys/fs/selinux can exercise the runtime-state branch they
      # otherwise never reach. Unset env = the real module's own paths.
      config_path = ENV["KRIKRI_SELINUX_CONFIG_PATH"]? || CONFIG_PATH
      enforce_path = ENV["KRIKRI_SELINUX_ENFORCE_PATH"]? || ENFORCE_PATH

      # Runtime probe (selinux.py:252-263): is_selinux_enabled() == 0
      # makes runtime_state 'disabled', else security_getenforce() picks
      # 'enforcing'/'permissive' - the kernel flag file's content stands
      # in for the C call, where anything but "1" (including an
      # unreadable file, i.e. the error return) is the falsy case.
      runtime_enabled = File.exists?(enforce_path)
      runtime_state = if runtime_enabled
                        enforce = begin
                          File.read(enforce_path).strip
                        rescue
                          ""
                        end
                        enforce == "1" ? "enforcing" : "permissive"
                      else
                        "disabled"
                      end

      if err = PluginHelpers::SelinuxConfig.state_validation_error(state)
        return PluginResult.new(changed: false, failed: true, msg: err)
      end
      state = state.not_nil!

      # Real selinux.py's first act in main() is the libselinux-python
      # import gate (HAS_SELINUX -> fail_json(msg=missing_required_lib(
      # 'libselinux-python'), exception=SELINUX_IMP_ERR)) - BEFORE the
      # config-file check, so a target whose python cannot import the
      # selinux bindings fails with that message no matter what
      # configfile: says. This plugin needs no python bindings, so it
      # used to carry on to its own "Unable to find file" failure
      # instead.
      if gate = Krikri.missing_python_library("libselinux-python", "selinux")
        return PluginResult.new(changed: false, failed: true, msg: gate[:msg])
      end

      # Ansible.posix.selinux ALWAYS fails when the config file is
      # missing - unconditionally, regardless of distro - confirmed
      # directly against the module's observed behavior
      # (`if not os.path.isfile(configfile): module.fail_json(msg=
      # "Unable to find file {0}".format(configfile), details="Please
      # install SELinux-policy package, if this package is not
      # installed previously.")`). There is no "SELinux not compiled
      # in, treat as no-op" special case anywhere in it - this plugin
      # previously assumed one (to let os_hardening "cleanly apply" to
      # Debian-family hosts), which was simply wrong: found live via
      # buluma.selinux on a Rocky 9.6 host missing the SELinux-policy
      # package, where Ansible failed with this exact message and
      # this plugin silently reported success instead.
      unless File.exists?(config_path)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unable to find file #{config_path}",
          details: "Please install SELinux-policy package, if this package is not installed previously."
        )
      end

      # Ansible's policy-required rule fires after the config-file check and
      # before any change computation - a state=enforcing call with no
      # policy: is a hard failure even when the state already matches.
      if PluginHelpers::SelinuxConfig.policy_required?(state, policy)
        return PluginResult.new(changed: false, failed: true, msg: "Policy is required if state is not 'disabled'")
      end

      # Read current config: extract SELINUX= and SELINUXTYPE= lines.
      original = File.read(config_path)
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
        # Ansible does the policy-store existence check inside
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
        File.write(config_path, lines.join("\n"))
      end

      msg = messages.empty? ? "Nothing to do" : messages.join(", ")
      msg += " (check mode)" if @check_mode && changed

      result = PluginResult.new(changed: changed, failed: false, msg: msg)
      if state != runtime_state && !runtime_enabled
        # selinux.py:322-324's runtime-disabled branch: krikri applies the
        # config write the module also applies, but with the runtime off
        # the state reaches the kernel only on the next boot, which the
        # module surfaces as module.warn(...) + reboot_required=true -
        # check mode included (that branch has no check_mode guard), and
        # without flipping `changed` on its own. The runtime-ENABLED
        # branches around it (setenforce / temporary-permissive-then-
        # reboot) are deliberately left un-implemented.
        existing = result.extra["warnings"]?.try(&.as_a?) || [] of JSON::Any
        result.extra["warnings"] = JSON::Any.new(existing + [JSON::Any.new("Reboot is required to set SELinux state to '#{state}'")])
        result.extra["reboot_required"] = JSON::Any.new(true)
      else
        # Every exit_json carries reboot_required, false whenever the
        # disabled branches didn't fire.
        result.extra["reboot_required"] = JSON::Any.new(false)
      end
      result
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
