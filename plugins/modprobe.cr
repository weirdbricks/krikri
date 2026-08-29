#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/modprobe_command"

module CrystalPlay
  # modprobe plugin - loads/unloads a kernel module. Compatible (for
  # the parameters implemented here) with Ansible's community.general.
  # modprobe module.
  #
  # Supported parameters:
  # - name (required)
  # - state: present (default) / absent
  # - check_mode
  #
  # Idempotency: checked via /sys/module/<name>'s existence (the same
  # thing `lsmod` itself reads from) rather than shelling to `lsmod`
  # and grepping its output.
  #
  # - params: extra modprobe arguments (e.g. "numdummies=2") passed
  #   straight to `modprobe <name> <params>` at load time - verified
  #   against real community.general modprobe.py's own source: only
  #   ever applied when the module ISN'T already loaded (`load_module`
  #   is only called from `not modprobe.module_loaded()`), so on an
  #   already-loaded module `params:` has zero effect and is never
  #   re-checked against what's currently loaded - `state: present`
  #   against an already-loaded module is a pure no-op regardless of
  #   `params:`, matching that exactly.
  #
  # Not implemented: persistent: present/absent (writing
  # /etc/modules-load.d//etc/modprobe.d/ entries so the module survives
  # a reboot) - konstruktoid/ansible-role-hardening's own only real
  # caller (loading nf_conntrack for ufw) doesn't use it.
  class ModprobePlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name

      state = @params["state"]? || "present"
      check_mode = true?(@params["check_mode"]?)
      loaded = module_loaded?(name)

      case state
      when "present"
        ensure_loaded(name, loaded, check_mode)
      when "absent"
        ensure_unloaded(name, loaded, check_mode)
      else
        PluginResult.new(changed: false, failed: true, msg: "state must be 'present' or 'absent', got '#{state}'")
      end
    end

    private def module_loaded?(name : String) : Bool
      # Kernel module directory names always use underscores, even when
      # the module is more commonly referred to with a dash (nf-
      # conntrack vs nf_conntrack) - normalize the same way modprobe(8)
      # itself does before checking.
      File.directory?("/sys/module/#{name.gsub('-', '_')}")
    end

    private def ensure_loaded(name : String, loaded : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "#{name} already loaded") if loaded
      return PluginResult.new(changed: true, failed: false, msg: "Would load #{name}") if check_mode

      result = remote_exec(PluginHelpers::ModprobeCommand.load_command(name, @params["params"]?))
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to load module #{name}", stderr: result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "Loaded #{name}")
    end

    private def ensure_unloaded(name : String, loaded : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "#{name} already unloaded") unless loaded
      return PluginResult.new(changed: true, failed: false, msg: "Would unload #{name}") if check_mode

      result = remote_exec("modprobe -r #{name}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to unload module #{name}", stderr: result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "Unloaded #{name}")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::ModprobePlugin.new(config)
plugin.run
