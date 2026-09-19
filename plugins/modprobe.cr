#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/modprobe_command"
require "../src/krikri/plugin_helpers/get_bin_path"

module Krikri
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
  # Binary resolution: real modprobe.py calls
  # `module.get_bin_path("modprobe", required=True)` in its __init__,
  # BEFORE any state check - so even `state: absent` against a module
  # that isn't loaded fails with `Failed to find required executable
  # "modprobe" in paths: ...` when the binary is missing (e.g. a
  # container without kmod). This plugin used to short-circuit on the
  # /sys/module check first and report "already unloaded" as success in
  # exactly that situation - a false success real Ansible doesn't
  # produce. Found via an ad-hoc CLI comparison sweep against real
  # ansible, 2026-09-13.
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
      # Real AnsibleModule validates the argument spec BEFORE anything
      # else runs (before get_bin_path, before any state check) - so a
      # bad state or missing name must win even when the modprobe binary
      # is missing. Verified live: with the binary hidden, real Ansible
      # still reports "value of state must be one of: ..." first.
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: name") unless name

      state = @params["state"]? || "present"
      unless state == "present" || state == "absent"
        return PluginResult.new(changed: false, failed: true, msg: "value of state must be one of: absent, present, got: #{state}")
      end

      if persistent = @params["persistent"]?
        unless persistent == "disabled" || persistent == "present" || persistent == "absent"
          return PluginResult.new(changed: false, failed: true, msg: "value of persistent must be one of: disabled, present, absent, got: #{persistent}")
        end
      end

      check_mode = true?(@params["_ansible_check_mode"]?)

      # Real modprobe.py resolves (and requires) the binary before
      # looking at module state at all - reproduce that ordering, or a
      # host without kmod gets "already unloaded" success instead of
      # real Ansible's executable-not-found failure.
      modprobe_path = find_modprobe_binary
      unless modprobe_path
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: PluginHelpers::GetBinPath.missing_executable_error("modprobe", @modprobe_searched_paths)
        )
      end

      loaded = module_loaded(name)
      if loaded.is_a?(String)
        return PluginResult.new(changed: false, failed: true, msg: loaded)
      end

      if state == "present"
        ensure_loaded(modprobe_path, name, loaded, check_mode)
      else
        ensure_unloaded(modprobe_path, name, loaded, check_mode)
      end
    end

    # Real modprobe.py's module_loaded(): scans /proc/modules for
    # "<name_> " (dash-normalized), then falls back to scanning
    # /lib/modules/$(uname -r)/modules.builtin for lines ending in
    # "/<name>.ko" (builtin modules count as loaded). Any OSError in
    # that sequence - typically a container without modules.builtin -
    # is an UNCAUGHT Python exception real Ansible surfaces as the
    # task failure "[Errno 2] No such file or directory: '...'", NOT
    # a clean yes/no. Returns the boolean, or the formatted OSError
    # text to fail the task with.
    private def module_loaded(name : String) : Bool | String
      path = "/proc/modules"
      begin
        module_name = "#{name.gsub('-', '_')} "
        is_loaded = false
        File.each_line(path) do |line|
          if line.starts_with?(module_name)
            is_loaded = true
            break
          end
        end
        return true if is_loaded

        module_file = "/#{name}.ko"
        path = "/lib/modules/#{kernel_release}/modules.builtin"
        File.each_line(path) do |line|
          return true if line.rstrip.ends_with?(module_file)
        end
        false
      rescue e : File::Error
        os_error_text(e, path)
      end
    end

    private def kernel_release : String
      File.read("/proc/sys/kernel/osrelease").chomp
    end

    # Formats the Errno the way Python's str(OSError) does - that text
    # is exactly what real Ansible surfaces when module_loaded()'s file
    # access fails.
    private def os_error_text(e : File::Error, path : String) : String
      errno = e.os_error.try(&.value)
      case errno
      when  2 then "[Errno 2] No such file or directory: '#{path}'"
      when 13 then "[Errno 13] Permission denied: '#{path}'"
      else         "[Errno #{errno}] #{e.message}"
      end
    end

    # Directories searched beyond $PATH for the modprobe binary. Real
    # Ansible's get_bin_path searches the module process's PATH only,
    # but a non-login shell's PATH routinely lacks /sbin//usr/sbin
    # (where modprobe lives) - the same reason ServicePlugin searches
    # these. Listed in the not-found message, mirroring real Ansible's
    # "in paths: ...".
    EXTRA_BIN_DIRS = %w[/sbin /usr/sbin /bin /usr/bin]

    @modprobe_searched_paths = ""

    # Resolves the modprobe binary the way real Ansible's
    # get_bin_path(modprobe, required=True) does - through the shell so
    # it works for both local and SSH connections - recording the
    # searched directories for the failure message. Returns nil when no
    # executable is found anywhere.
    private def find_modprobe_binary : String?
      dirs = %($(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')})
      script = <<-SH
      searched=""
      found=""
      for d in #{dirs}; do
        case ":$searched:" in *":$d:"*) continue ;; esac
        searched="${searched:+$searched:}$d"
        if [ -z "$found" ] && [ -x "$d/modprobe" ]; then found="$d/modprobe"; fi
      done
      printf 'searched=%s\n' "$searched"
      printf 'found=%s\n' "$found"
      SH

      parsed = PluginHelpers::ModprobeCommand.parse_bin_probe(remote_exec(script)[:stdout].to_s)
      @modprobe_searched_paths = parsed[:searched_paths]
      parsed[:path]
    end

    private def ensure_loaded(modprobe_path : String, name : String, loaded : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "#{name} already loaded") if loaded
      return PluginResult.new(changed: true, failed: false, msg: "Would load #{name}") if check_mode

      result = remote_exec(PluginHelpers::ModprobeCommand.load_command(modprobe_path, name, @params["params"]?))
      unless result[:exit_code] == 0
        # Real modprobe.py's load_module: fail_json(msg=err, ...) - the
        # msg IS the raw modprobe stderr, not a wrapper sentence.
        return PluginResult.new(changed: false, failed: true, msg: result[:stderr].to_s, stderr: result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "Loaded #{name}")
    end

    private def ensure_unloaded(modprobe_path : String, name : String, loaded : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "#{name} already unloaded") unless loaded
      return PluginResult.new(changed: true, failed: false, msg: "Would unload #{name}") if check_mode

      result = remote_exec("#{modprobe_path} -r #{Process.quote(name)}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: result[:stderr].to_s, stderr: result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "Unloaded #{name}")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::ModprobePlugin.new(config)
plugin.run
