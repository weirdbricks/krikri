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
  #   configfile (optional, default /etc/selinux/config, aliases conf/file):
  #     the file both read and rewritten instead of the default path
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

    # ansible.posix's module_utils/_respawn.py SYSTEM_PYTHON_INTERPRETERS,
    # verbatim - the order respawn_module("selinux") probes.
    SYSTEM_PYTHON_INTERPRETERS = [
      "/usr/bin/libexec/platform-python",
      "/usr/bin/python3",
      "/usr/bin/python2",
      "/usr/bin/python",
    ]

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
      config_path = config_file_path
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
      # instead. That failure is not unconditional in real, though: the
      # gate first respawns the module under a system interpreter that
      # DOES have the bindings (see respawnable_python?), which is how
      # a Rocky 9 host whose discovered python3.12 lacks them still
      # reports changed via /usr/bin/python3 (issue #1513).
      if gate = Krikri.missing_python_library("libselinux-python", "selinux")
        return PluginResult.new(changed: false, failed: true, msg: gate[:msg]) unless respawnable_python?
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
      config_changed = false
      messages = [] of String

      if state && state != current_state
        messages << "state #{current_state.inspect} -> #{state}"
        changed = true
        config_changed = true
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
        config_changed = true
      end

      # selinux.py:290-324's runtime-state block, whose warnings are what
      # a krikri run was missing on hosts with SELinux ENABLED at
      # runtime: disabling drops the runtime to permissive for the rest
      # of this boot (warned, and the flip itself only outside check
      # mode), an already-permissive runtime only warns, and enabling/
      # permissive reaches the kernel immediately - each reporting
      # reboot_required and flipping `changed` exactly as real does. The
      # runtime-disabled half (below) warns that the next boot applies
      # it.
      warnings = [] of String
      reboot_required = false
      if state != runtime_state
        if runtime_enabled
          if state == "disabled"
            if runtime_state != "permissive"
              set_runtime_state(permissive: true, enforce_path: enforce_path) unless @check_mode
              warnings << "SELinux state temporarily changed from '#{runtime_state}' to 'permissive'. State change will take effect next reboot."
              changed = true
            else
              warnings << "SELinux state change will take effect next reboot"
            end
            reboot_required = true
          else
            set_runtime_state(permissive: state == "permissive", enforce_path: enforce_path) unless @check_mode
            messages << "SELinux state changed from '#{runtime_state}' to '#{state}'"
            changed = true
          end
        else
          warnings << "Reboot is required to set SELinux state to '#{state}'"
          reboot_required = true
        end
      end

      if config_changed && !@check_mode
        File.write(config_path, lines.join("\n"))
      end

      msg = messages.empty? ? "Nothing to do" : messages.join(", ")
      msg += " (check mode)" if @check_mode && changed

      result = PluginResult.new(changed: changed, failed: false, msg: msg)
      unless warnings.empty?
        result.extra["warnings"] = JSON::Any.new(warnings.map { |warning| JSON::Any.new(warning) })
      end
      # Every exit_json carries reboot_required, false whenever none of
      # the branches above fired.
      result.extra["reboot_required"] = JSON::Any.new(reboot_required)
      result
    end

    # ansible.posix.selinux's `configfile` parameter (type str, default
    # /etc/selinux/config, aliases conf/file) names the file every check
    # and rewrite targets. AnsibleModule's _handle_aliases copies a
    # present alias over the canonical key, so the aliases win. This
    # plugin used to hardwire CONFIG_PATH, so `configfile: jssvzf`
    # silently checked /etc/selinux/config instead and reported the
    # later policy-store error where real fails with "Unable to find
    # file jssvzf" first.
    private def config_file_path : String
      @params["conf"]? || @params["file"]? || @params["configfile"]? ||
        ENV["KRIKRI_SELINUX_CONFIG_PATH"]? || CONFIG_PATH
    end

    # selinux.py:240-243's `respawn_module("selinux")`: when the task's
    # interpreter cannot import the bindings, the module re-executes
    # itself under the first SYSTEM_PYTHON_INTERPRETERS entry that can,
    # and that copy's flow is the same config read/rewrite this plugin
    # already runs - so finding one makes the task proceed exactly as if
    # the task interpreter had the bindings. Only when no candidate
    # carries them does real fall through to its missing_required_lib
    # failure. The env override is a spec seam, like the config/enforce
    # path overrides above: a colon-separated list replaces the probe
    # order.
    private def respawnable_python? : Bool
      candidates = ENV["KRIKRI_SELINUX_RESPAWN_INTERPRETERS"]?.try(&.split(':')) || SYSTEM_PYTHON_INTERPRETERS
      candidates.any? do |interpreter|
        next false if interpreter.empty?

        Process.run(interpreter, {"-c", "import selinux"},
          output: Process::Redirect::Close, error: Process::Redirect::Close).success?
      rescue
        false
      end
    end

    # selinux.py:181-190's set_state: security_setenforce(1) for
    # enforcing, (0) for permissive - the same boolean the kernel flag
    # file holds, so writing it is the binding-free equivalent. Real
    # calls it only outside check mode and ignores its return value.
    private def set_runtime_state(permissive : Bool, enforce_path : String) : Nil
      File.write(enforce_path, permissive ? "0" : "1")
    rescue
      # The C binding's failure is not inspected by real either.
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
