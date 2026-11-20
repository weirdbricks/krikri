#!/usr/bin/env crystal
# community.general.cpanm - installs Perl modules via `cpanm`. Behavior
# matched to the Ansible module (systemli.spamassasin's dmarc.yml runs it):
# - a module already loadable by `perl -le 'use <name>; print "OK";'` is
#   left alone (changed=false); a .tar.gz name is never "installed".
# - changed is rc==0 and no "is up to date" in cpanm's output.
# - failure carries cmd (executable resolved to its full path), rc,
#   stdout and stderr, with msg being cpanm's stderr.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/cpanm"
require "../src/krikri/plugin_helpers/run_command_failure"

module Krikri
  class CpanmPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?.presence
      from_path = @params["from_path"]?.presence
      if preflight = argument_check(name, from_path)
        return preflight
      end

      locallib = @params["locallib"]?.presence
      executable = @params["executable"]?.presence || "cpanm"

      resolved = remote_exec("command -v #{Process.quote(executable)}")
      return PluginResult.new(changed: false, failed: true,
        msg: missing_executable_message(executable)) if resolved[:exit_code] != 0
      cpanm = resolved[:stdout].strip

      if name && !from_path
        probe = PluginHelpers::Cpanm.probe_command(name, @params["version"]?.presence, locallib)
        if probe && remote_exec(probe)[:exit_code] == 0
          return PluginResult.new(changed: false, failed: false)
        end
      end

      argv = PluginHelpers::Cpanm.install_argv(cpanm, (from_path || name).to_s,
        true?(@params["notest"]?), locallib, @params["mirror"]?.presence,
        true?(@params["mirror_only"]?), true?(@params["installdeps"]?))
      # AnsibleModule.run_command pins the locale to C, so perl never prints
      # its "Setting locale failed" warnings into the captured stderr.
      result = remote_exec("LANGUAGE=C LC_ALL=C LC_MESSAGES=C " + argv.map { |token| Process.quote(token) }.join(" "))

      if result[:exit_code] != 0
        failure = PluginHelpers::RunCommandFailure.nonzero_exit(argv.join(" "),
          result[:exit_code], result[:stdout], result[:stderr])
        # nonzero_exit leaves the *_lines empty for the display layer to
        # fill, which it does not for a looped item's failed line; ansible's
        # failure dict carries the real splits.
        failure.extra["stdout_lines"] = JSON::Any.new(result[:stdout].lines.map { |line| JSON::Any.new(line) })
        failure.extra["stderr_lines"] = JSON::Any.new(result[:stderr].lines.map { |line| JSON::Any.new(line) })
        return failure
      end

      PluginResult.new(changed: PluginHelpers::Cpanm.changed?(result[:exit_code], result[:stdout], result[:stderr]),
        failed: false)
    end

    # Ansible's failure ordering, reproduced in the order it happens:
    # basic.py's argument-spec validation (required_one_of) runs first,
    # then the check-mode gate, then the module's own __init_module__
    # raises.
    private def argument_check(name : String?, from_path : String?) : PluginResult?
      unless name || from_path
        return PluginResult.new(changed: false, failed: true,
          msg: "one of the following is required: name, from_path")
      end

      # cpanm.py passes no supports_check_mode to its AnsibleModule, so
      # basic.py's gate skips the task under --check before the module
      # body (and its own mode checks) runs. The registered result
      # carries an explicit failed: false (Ansible's controller-side
      # _return_formatted backfill), so `kpg_task_0.failed` is defined.
      if true?(@params["_ansible_check_mode"]?)
        invoked = @params["_module_name"]? || "community.general.cpanm"
        return PluginResult.new(changed: false, failed: false,
          msg: "remote module (#{invoked}) does not support check mode", skipped: true,
          failed_flag: true)
      end

      mode = @params["mode"]?.presence || "new"
      if setup_error = PluginHelpers::Cpanm.setup_error(name, from_path, mode, @params["name_check"]?.presence)
        return setup_failure(setup_error)
      end
      nil
    end

    # ModuleHelper's fail_json shape for a raise inside __init_module__:
    # the output_params (name, version) ride along under both `output` and
    # `vars` AND are repeated at the top level, and --diff adds an empty
    # `diff` dict to the result and to `output` (live-captured: ansible-core
    # 2.21.6 with community.general 12.5.0, the pair kpg round fixtures run).
    private def setup_failure(msg : String) : PluginResult
      name = @params["name"]?.presence
      version = @params["version"]?.presence
      empty_diff = JSON::Any.new({} of String => JSON::Any)
      output = Hash(String, JSON::Any).new
      output["name"] = JSON::Any.new(name)
      output["version"] = JSON::Any.new(version)
      output["diff"] = empty_diff if @diff_mode
      vars = Hash(String, JSON::Any).new
      vars["name"] = JSON::Any.new(name)
      vars["version"] = JSON::Any.new(version)
      PluginResult.new(changed: false, failed: true, msg: msg,
        diff: @diff_mode ? empty_diff : nil,
        name: name, version: version,
        output: JSON::Any.new(output), vars: JSON::Any.new(vars),
        key_order: ["changed", "failed", "exception", "msg", "diff", "output", "vars", "name", "version"])
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::CpanmPlugin.new(config)
plugin.run
