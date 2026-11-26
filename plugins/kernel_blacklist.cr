#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/kernel_blacklist_file"

module Krikri
  # kernel_blacklist plugin (community.general.kernel_blacklist) -
  # adds/removes `blacklist <module>` entries in a modprobe.d file.
  #
  # Pure file editing - the Ansible module never touches modprobe itself
  # (blacklisting only affects the NEXT probe/load, never an
  # already-loaded module), so neither does this. Params:
  # - name: required. Kernel module name.
  # - state: present (default) / absent.
  # - blacklist_file: target file, default
  #   /etc/modprobe.d/blacklist-ansible.conf (the Ansible module's own
  #   default - not the historical /etc/modprobe.d/blacklist.conf).
  #
  # Mirrors the Ansible module's (StateModuleHelper) flow exactly:
  # __init_module__ creates a missing file with an append open BEFORE
  # any check-mode gate and counts the creation as a change on its own
  # (state=absent against a missing file still reports changed=true),
  # entries match `^blacklist\s+<name>$` on stripped non-comment lines,
  # lines are read with a right-strip (trailing whitespace lost on
  # rewrite), and the write happens only when changed and not in check
  # mode. Ansible's result carries no msg key (only the output_params
  # name/state), so the msg stays empty here - an empty msg is omitted
  # from the result JSON, and `msg | default('none')` sees the same
  # 'none' Ansible reports.
  class KernelBlacklistPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Ansible's argument_spec (community.general kernel_blacklist.py) - no
    # aliases, so the unsupported-params message has no parenthetical.
    # Note the choices declaration order (absent, present) - Ansible's
    # choices error lists them in that order.
    SPEC = {
      "blacklist_file" => %w[],
      "name"           => %w[],
      "state"          => %w[],
    }

    # AnsibleModule setup surface, in the validator's errors[0]
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

      name = @params["name"]
      state = @params["state"]? || "present"
      file = @params["blacklist_file"]? || "/etc/modprobe.d/blacklist-ansible.conf"
      check_mode = true?(@params["_ansible_check_mode"]?)

      # Ansible's __init_module__ creates a missing file with an append
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
          return failed_result(name, state, file,
            "Module failed with exception: [Errno 2] No such file or directory: '#{file}'")
        end
        # kernel_blacklist.py creates it with a bare `open(path, "a")`,
        # which asks the kernel for 0666 and lets the process umask take
        # the rest (0644 under the reference images' 022, 0664 under the
        # developer default 002). File.touch would pin 0644 instead and
        # silently drop the umask's group-write bit.
        File.open(file, "a", perm: 0o666) { }
      end
      lines = file_existed ? File.read_lines(file).map(&.rstrip) : nil

      initial_lines = lines || [] of String
      new_lines, changed = PluginHelpers::KernelBlacklistFile.apply(lines, name, state)

      if changed && !check_mode
        File.write(file, new_lines.map { |line| line + "\n" }.join)
      end

      # Real StateModuleHelper output (live-verified against Ansible 2.19.11
      # in the podman container; check mode, changed and unchanged runs
      # and state=absent all identical):
      # changed, name, state, filename, lines, is_blacklisted.
      # --diff appends the VarDict diff for `lines` (the module's only
      # diff-flagged variable) after every output variable.
      PluginResult.new(
        changed: changed,
        failed: false,
        name: name,
        state: state,
        filename: file,
        lines: new_lines,
        is_blacklisted: PluginHelpers::KernelBlacklistFile.blacklisted?(new_lines, name),
        diff: PluginHelpers::KernelBlacklistFile.diff_payload(initial_lines, new_lines, diff_mode?),
        key_order: ["changed", "name", "state", "filename", "lines", "is_blacklisted", "diff"],
      )
    end

    # Ansible's failure result carries the module's own state surface along
    # with the message: the resolved filename, the module name, the
    # requested state, and the output/vars dicts (StateModuleHelper's
    # output_params under both keys) - live-captured from
    # ansible-playbook 2.19.11 in a container where /etc/modprobe.d
    # doesn't exist yet.
    private def failed_result(name : String, state : String, file : String, msg : String) : PluginResult
      vars = {
        "name"     => JSON::Any.new(name),
        "state"    => JSON::Any.new(state),
        "filename" => JSON::Any.new(file),
      }
      output = vars.dup
      # module_helper merges the VarDict's diff into the output dict under
      # --diff - empty here, because the OSError raise happens before
      # __init_module__ sets any diff-flagged variable - and the
      # module_fails_on_exception decorator spreads that same dict at the
      # top level. `vars` stays diff-free (real 2.21.6 register dump).
      empty_diff = JSON::Any.new({} of String => JSON::Any)
      output["diff"] = empty_diff if diff_mode?
      PluginResult.new(changed: false, failed: true, msg: msg,
        filename: file, name: name, state: state,
        output: JSON::Any.new(output), vars: JSON::Any.new(vars),
        diff: diff_mode? ? empty_diff : nil,
        # Real 2.21.6 register order: fail_json's own kwargs (msg, output,
        # vars) first, then the output dict it spreads (name, state,
        # filename), with the 2.21 task-result leading keys moved ahead.
        key_order: ["failed", "msg", "diff", "output", "vars", "name", "state", "filename"])
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::KernelBlacklistPlugin.new(config)
plugin.run
