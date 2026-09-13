module Krikri
  module PluginHelpers
    # Real Ansible's module_utils/basic.py get_bin_path(required=True):
    # resolves a module's required binary at module start, BEFORE any
    # state check, and fails with exactly this message when nothing
    # executable is found - so even a state-only task
    # (`modprobe: name=x state=absent` against an unloaded module)
    # fails on a host that lacks the binary. This engine's plugins used
    # to short-circuit on their own state checks first and report
    # "already in desired state" success on hosts where the underlying
    # binary was missing entirely - a false success real Ansible never
    # produces. Found via an ad-hoc CLI comparison sweep against real
    # ansible, 2026-09-13.
    module GetBinPath
      extend self

      # *searched_paths* is the colon-joined directory list the probe
      # actually searched (the module process's $PATH, plus the extra
      # sbin dirs this engine's plugins search because a non-login
      # shell's PATH routinely lacks them).
      def missing_executable_error(name : String, searched_paths : String) : String
        %(Failed to find required executable "#{name}" in paths: #{searched_paths})
      end
    end
  end
end
