#!/usr/bin/env crystal
# community.general.cpanm - installs Perl modules via `cpanm`. Behavior
# matched to the Ansible module (systemli.spamassasin's dmarc.yml runs it):
# - mode=new (the default since community.general 9.0.0) refuses
#   name+from_path together and folds `version` into the package spec;
#   mode=compatibility is the old behavior, where `name` is probed with
#   `perl -le 'use <name>; print "OK";'` (a .tar.gz name is never
#   "installed") and skipped when present. mode=new only probes when the
#   caller passes a separate name_check.
# - changed is rc==0 and no "is up to date" in cpanm's output.
# - failure carries cmd (executable resolved to its full path), rc,
#   stdout and stderr, with msg being cpanm's stderr.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/cpanm"
require "../src/krikri/plugin_helpers/run_command_failure"

module Krikri
  class CpanmPlugin < BasePlugin
    # AnsibleModule.run_command pins the locale to C for every exec the
    # module makes, so perl never prints its "Setting locale failed"
    # warnings into the captured stderr.
    LOCALE_ENV = "LANGUAGE=C LC_ALL=C LC_MESSAGES=C "

    # The resolved cpanm and the version __init_module__ reads back from
    # it; both land in every result the module exits with afterwards.
    private record Binary, path : String, version : String

    def execute : PluginResult
      name = @params["name"]?.presence
      from_path = @params["from_path"]?.presence
      mode = @params["mode"]?.presence || PluginHelpers::Cpanm::DEFAULT_MODE

      if failure = validation_failure(name, from_path, mode)
        return failure
      end

      binary = resolve_cpanm
      return binary if binary.is_a?(PluginResult)

      version = @params["version"]?.presence
      locallib = @params["locallib"]?.presence
      if installed_probe(mode, name, @params["name_check"]?.presence, version, locallib)
        return success_result(false, binary)
      end

      spec = package_spec(mode, name, from_path, version, binary)
      return spec if spec.is_a?(PluginResult)
      install(spec, binary, locallib)
    end

    # The three checks Ansible runs before cpanm is even looked up, in
    # their real order: AnsibleModule's argument-spec validation, the skip
    # of a module without check-mode support, then the module's own
    # __init_module__ argument checks.
    private def validation_failure(name : String?, from_path : String?, mode : String) : PluginResult?
      unless name || from_path
        return PluginResult.new(changed: false, failed: true,
          msg: "one of the following is required: name, from_path")
      end
      unless PluginHelpers::Cpanm::MODES.includes?(mode)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of mode must be one of: #{PluginHelpers::Cpanm::MODES.join(", ")}, got: #{mode}")
      end
      return check_mode_skip if true?(@params["_ansible_check_mode"]?)
      if error = PluginHelpers::Cpanm.argument_error(mode, name, from_path, @params["name_check"]?.presence)
        return module_helper_failure(error)
      end
      nil
    end

    # cpanm declares check_mode: support: none, and AnsibleModule skips
    # such a module after argument-spec validation but before any module
    # body runs. The registered result carries an explicit failed: false
    # (Ansible's controller-side _return_formatted backfill), so a later
    # `kpg_task_0 is succeeded` sees the key defined.
    private def check_mode_skip : PluginResult
      invoked = @params["_module_name"]? || "community.general.cpanm"
      PluginResult.new(changed: false, failed: false, skipped: true, failed_flag: true,
        msg: "remote module (#{invoked}) does not support check mode")
    end

    # get_bin_path(required=True) for the executable, then
    # __init_module__'s `cpanm --version` version parse.
    private def resolve_cpanm : Binary | PluginResult
      executable = @params["executable"]?.presence || "cpanm"
      resolved = remote_exec("command -v #{Process.quote(executable)}")
      if resolved[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: missing_executable_message(executable))
      end
      cpanm = resolved[:stdout].strip

      probed = remote_exec(LOCALE_ENV + Process.quote(cpanm) + " --version")
      if probed[:exit_code] != 0
        return PluginHelpers::RunCommandFailure.nonzero_exit("#{cpanm} --version",
          probed[:exit_code], probed[:stdout], probed[:stderr])
      end
      first_line = probed[:stdout].lines.first? || ""
      unless version_match = first_line.match(/version\s+([\d\.]+)\s/)
        return module_helper_failure(
          "Failed to determine version number. First line of output: #{first_line}", binary: cpanm)
      end
      Binary.new(cpanm, version_match[1])
    end

    # mode=new only checks an explicitly named name_check module;
    # compatibility mode probes `name` itself and skips the install when
    # the module is already loadable.
    private def installed_probe(mode : String, name : String?, name_check : String?,
                                version : String?, locallib : String?) : Bool
      probe_name = mode == "new" ? name_check : name
      return false unless probe_name
      probe = PluginHelpers::Cpanm.probe_command(probe_name, version, locallib)
      return false unless probe
      remote_exec(probe)[:exit_code] == 0
    end

    private def package_spec(mode : String, name : String?, from_path : String?,
                             version : String?, binary : Binary) : String | PluginResult
      spec = (from_path || name).to_s
      return spec unless mode == "new" && version
      directory = !spec.ends_with?(".tar.gz") && directory?(spec)
      if error = PluginHelpers::Cpanm.spec_version_error(spec, version, directory)
        return module_helper_failure(error, binary: binary.path, cpanm_version: binary.version)
      end
      PluginHelpers::Cpanm.versioned_spec(spec, version)
    end

    private def install(spec : String, binary : Binary, locallib : String?) : PluginResult
      argv = PluginHelpers::Cpanm.install_argv(binary.path, spec,
        true?(@params["notest"]?), locallib, @params["mirror"]?.presence,
        true?(@params["mirror_only"]?), true?(@params["installdeps"]?),
        tri_bool("install_recommendations"), tri_bool("install_suggestions"))
      result = remote_exec(LOCALE_ENV + argv.map { |token| Process.quote(token) }.join(" "))
      return install_failure(argv, result) if result[:exit_code] != 0
      success_result(PluginHelpers::Cpanm.changed?(result[:exit_code], result[:stdout], result[:stderr]),
        binary)
    end

    private def install_failure(argv : Array(String),
                                result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      failure = PluginHelpers::RunCommandFailure.nonzero_exit(argv.join(" "),
        result[:exit_code], result[:stdout], result[:stderr])
      # nonzero_exit leaves the *_lines empty for the display layer to
      # fill, which it does not for a looped item's failed line; ansible's
      # failure dict carries the real splits.
      failure.extra["stdout_lines"] = JSON::Any.new(result[:stdout].lines.map { |line| JSON::Any.new(line) })
      failure.extra["stderr_lines"] = JSON::Any.new(result[:stderr].lines.map { |line| JSON::Any.new(line) })
      failure
    end

    # exit_json(changed=, **output) where output is the module's output
    # params (name, version) plus the vars __init_module__ set afterwards
    # (binary, cpanm_version) - VarDict.set defaults output=True.
    private def success_result(changed : Bool, binary : Binary) : PluginResult
      params = output_params(binary.path, binary.version)
      result = PluginResult.new(changed: changed, failed: false, failed_flag: false,
        key_order: ["changed", "failed"] + params.keys)
      params.each { |key, value| result.extra[key] = value }
      result
    end

    # module_fails_on_exception's failure shape: fail_json(msg=,
    # exception=, output=self.output, vars=self.vars.output(), **output).
    # Only output-flagged vars reach the dicts: name/version always, plus
    # binary/cpanm_version once __init_module__ has resolved and probed
    # cpanm. `diff` is appended to `output` (--diff) and spread at top
    # level like any other output var; the callback drops it from dumps.
    private def module_helper_failure(msg : String, binary : String? = nil,
                                      cpanm_version : String? = nil) : PluginResult
      vars = output_params(binary, cpanm_version)
      output = vars.dup
      output["diff"] = JSON::Any.new({} of String => JSON::Any) if diff_mode?

      result = PluginResult.new(changed: false, failed: true, msg: msg,
        key_order: ["output", "vars"] + output.keys + ["failed", "msg", "changed", "exception"])
      result.extra["output"] = JSON::Any.new(output)
      result.extra["vars"] = JSON::Any.new(vars)
      output.each { |key, value| result.extra[key] = value }
      result
    end

    # The module's output dict in its real wire order: the output-flagged
    # argument_spec params (name, version) first, then the vars
    # __init_module__ sets later (binary, cpanm_version).
    private def output_params(binary : String? = nil, cpanm_version : String? = nil) : Hash(String, JSON::Any)
      params = Hash(String, JSON::Any).new
      {"name", "version"}.each { |key| params[key] = output_param(key) }
      params["binary"] = JSON::Any.new(binary) if binary
      params["cpanm_version"] = JSON::Any.new(cpanm_version) if cpanm_version
      params
    end

    # Ansible params are always present (an unset one is None), so the dump
    # carries "name": null rather than omitting it.
    private def output_param(key : String) : JSON::Any
      value = @params[key]?
      return JSON::Any.new(nil) if value.nil? || value.empty? || explicit_null_param?(key)
      JSON::Any.new(value)
    end

    # A tri-state bool arg (cmd_runner_fmt.as_bool(.., ignore_none=True)):
    # nil when the playbook did not pass it.
    private def tri_bool(key : String) : Bool?
      raw = @params[key]?.presence
      raw ? true?(raw) : nil
    end

    private def directory?(path : String) : Bool
      remote_exec("test -d #{Process.quote(path)}")[:exit_code] == 0
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::CpanmPlugin.new(config)
plugin.run
