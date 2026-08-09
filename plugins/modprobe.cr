#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

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
  # Not implemented: params: (extra modprobe arguments, e.g. "arg=val"
  # passed straight to the module at load time) and persistent: present/
  # absent (writing /etc/modules-load.d//etc/modprobe.d/ entries so the
  # module survives a reboot) - konstruktoid/ansible-role-hardening's
  # own only real caller (loading nf_conntrack for ufw) uses neither.
  class ModprobePlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name

      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)
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

      result = remote_exec("modprobe #{name}")
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
