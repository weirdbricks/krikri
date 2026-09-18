#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/kernel_blacklist_file"

module Krikri
  # kernel_blacklist plugin (community.general.kernel_blacklist) -
  # adds/removes `blacklist <module>` entries in a modprobe.d file.
  #
  # Pure file editing - the real module never touches modprobe itself
  # (blacklisting only affects the NEXT probe/load, never an
  # already-loaded module), so neither does this. Params:
  # - name: required. Kernel module name.
  # - state: present (default) / absent.
  # - blacklist_file: target file, default
  #   /etc/modprobe.d/blacklist-ansible.conf (the real module's own
  #   default - not the historical /etc/modprobe.d/blacklist.conf).
  #
  # Mirrors the real module's (StateModuleHelper) flow exactly:
  # __init_module__ creates a missing file with an append open BEFORE
  # any check-mode gate and counts the creation as a change on its own
  # (state=absent against a missing file still reports changed=true),
  # entries match `^blacklist\s+<name>$` on stripped non-comment lines,
  # lines are read with a right-strip (trailing whitespace lost on
  # rewrite), and the write happens only when changed and not in check
  # mode. Real's result carries no msg key (only the output_params
  # name/state), so the msg stays empty here - an empty msg is omitted
  # from the result JSON, and `msg | default('none')` sees the same
  # 'none' real Ansible reports.
  class KernelBlacklistPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real argument_spec (community.general kernel_blacklist.py) - no
    # aliases, so the unsupported-params message has no parenthetical.
    # Note the choices declaration order (absent, present) - real's
    # choices error lists them in that order.
    SPEC = {
      "blacklist_file" => %w[],
      "name"           => %w[],
      "state"          => %w[],
    }

    # Real AnsibleModule setup surface, in the validator's errors[0]
    # order (arg_spec.py: required -> choices -> unsupported). No
    # bool/int params in the spec, so no type checks.
    private def validate_arguments : PluginResult?
      unless @params["name"]?
        return missing_required_error(["name"])
      end

      state = @params["state"]? || "present"
      unless %w[present absent].includes?(state)
        return choices_error("state", %w[absent present], state)
      end

      if unsupported = unsupported_param_keys(@params, SPEC)
        unless unsupported.empty?
          return unsupported_params_error("community.general.kernel_blacklist", unsupported, SPEC)
        end
      end

      nil
    end

    def execute : PluginResult
      if error = validate_arguments
        return error
      end

      name = @params["name"].not_nil!
      state = @params["state"]? || "present"
      file = @params["blacklist_file"]? || "/etc/modprobe.d/blacklist-ansible.conf"
      check_mode = true?(@params["_ansible_check_mode"]?)

      # Real's __init_module__ creates a missing file with an append
      # open BEFORE any check-mode gate (and before evaluating the
      # state), and counts the creation as a change on its own -
      # state=absent against a missing file still reports changed=true.
      # The append open can't create parent directories: a missing
      # parent fails the module with the wrapped OSError wording
      # (live-verified in the real container, where /etc/modprobe.d
      # doesn't exist until kmod does).
      file_existed = File.exists?(file)
      unless file_existed
        parent = File.dirname(file)
        unless Dir.exists?(parent)
          return PluginResult.new(changed: false, failed: true,
            msg: "Module failed with exception: [Errno 2] No such file or directory: '#{file}'")
        end
        File.touch(file)
      end
      lines = file_existed ? File.read_lines(file).map(&.rstrip) : nil

      new_lines, changed = PluginHelpers::KernelBlacklistFile.apply(lines, name, state)

      if changed && !check_mode
        File.write(file, new_lines.map { |line| line + "\n" }.join)
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: "",
      )
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::KernelBlacklistPlugin.new(config)
plugin.run
