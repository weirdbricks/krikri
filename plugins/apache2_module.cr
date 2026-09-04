#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/apache2_module"

module Krikri
  # Apache2 module plugin - enables/disables Apache modules via
  # a2enmod/a2dismod
  # Compatible with (a subset of) community.general.apache2_module
  #
  # Parameters:
  #   name (required): module name as given to a2enmod/a2dismod
  #   state: present (default) or absent
  #   identifier (optional): the name the module appears under in
  #     `apache2ctl -M` output; defaults to name_module, with the real
  #     module's workarounds for shib/shib2 (mod_shib), evasive
  #     (evasive20_module) and php/php8 spellings
  #   force: pass -f to a2dismod (disabling default modules)
  #   ignore_configcheck: treat a failing `apache2ctl -M` (broken
  #     configuration unrelated to this task) as "not enabled" and fall
  #     back to a2enmod/a2dismod's own wording for the changed? decision
  #   warn_mpm_absent: silence the missing-MPM warning emitted under
  #     ignore_configcheck when -M fails with AH00534 on an mpm_ module
  #     (default true, i.e. warn)
  #   check_mode: report would-be changes without running a2enmod/a2dismod
  #
  # Behavior verified live against a real Debian-family host (Ubuntu
  # 22.04 container, real apache2 package): a2enmod/a2dismod do the
  # actual symlink work in /etc/apache2/mods-enabled - the module never
  # touches those files itself - and `apache2ctl -M` enableset checks
  # are a plain " <identifier>" substring test on its stdout. Real
  # bug-surface found there: a *failed* `apache2ctl -M` (e.g. AH00534
  # with no MPM loaded) must not fail the task when
  # ignore_configcheck is set, and the cgi/ threaded-MPM pre-check
  # fires before any state change.
  class Apache2ModulePlugin < BasePlugin
    @warnings = [] of String

    def execute : PluginResult
      run_execute
    rescue e : ModuleError
      # Real module.fail_json - a failure result, not a crash
      PluginResult.new(changed: false, failed: true, msg: e.message || "apache2_module failed")
    end

    private def run_execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      state = @params["state"]? || "present"
      unless state == "present" || state == "absent"
        return PluginResult.new(changed: false, failed: true, msg: "state must be present or absent, got: #{state}")
      end

      identifier = @params["identifier"]?.presence || PluginHelpers::Apache2Module.create_identifier(name)

      # Real main(): refuses to enable cgi under a threaded MPM before
      # touching anything (a2enmod would fail later with a less clear
      # error). apache2ctl -V is matched against threaded: *yes.
      if name == "cgi" && state == "present" && run_threaded?
        return PluginResult.new(changed: false, failed: true, msg: "Your MPM seems to be threaded, therefore enabling cgi module is not allowed.")
      end

      result = set_state(name, state, identifier)
      result.extra["warnings"] = JSON.parse(@warnings.to_json) unless @warnings.empty?
      result
    end

    private def set_state(name : String, state : String, identifier : String) : PluginResult
      want_enabled = state == "present"
      state_string = want_enabled ? "enabled" : "disabled"
      a2mod_binary = want_enabled ? "a2enmod" : "a2dismod"
      success_msg = "Module #{name} #{state_string}"
      check_mode = true?(@params["check_mode"]?)

      currently_enabled, _ = module_is_enabled(identifier, name)
      if currently_enabled == want_enabled
        return PluginResult.new(changed: false, failed: false, msg: success_msg, result: success_msg)
      end

      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: success_msg, result: success_msg)
      end

      # Real get_bin_path(a2mod_binary) - only checked once a change is
      # actually needed.
      a2mod_path = remote_exec("command -v #{a2mod_binary} 2>/dev/null")
      if a2mod_path[:exit_code] != 0 || a2mod_path[:stdout].strip.empty?
        return PluginResult.new(changed: false, failed: true, msg: "#{a2mod_binary} not found. Perhaps this system does not use #{a2mod_binary} to manage apache")
      end

      # force exists only for a2dismod on debian
      force_flag = !want_enabled && true?(@params["force"]?) ? "-f " : ""
      run = remote_exec("export LANGUAGE=C LC_ALL=C; #{a2mod_path[:stdout].strip.split("\n").first} #{force_flag}#{shell_single_quote(name)}")

      return a2mod_failure(a2mod_binary, name, run) if run[:exit_code] != 0

      verify_change(name, state_string, identifier, want_enabled, run)
    end

    private def a2mod_failure(a2mod_binary : String, name : String, run) : PluginResult
      PluginResult.new(
        changed: false,
        failed: true,
        msg: "Failed to run #{a2mod_binary} for module #{name}:\n#{run[:stdout]}\n#{run[:stderr]}",
        rc: run[:exit_code],
        stdout: run[:stdout],
        stderr: run[:stderr]
      )
    end

    # Real _set_state's post-command verification: confirm via a fresh
    # `apache2ctl -M` that the module is now in the wanted state.
    private def verify_change(name : String, state_string : String, identifier : String, want_enabled : Bool, run) : PluginResult
      success_msg = "Module #{name} #{state_string}"
      now_enabled, configcheck_failed = module_is_enabled(identifier, name)
      if now_enabled == want_enabled
        PluginResult.new(changed: true, failed: false, msg: success_msg, result: success_msg)
      elsif configcheck_failed
        # apache2ctl -M could not confirm the new state because the
        # configuration is broken for a reason unrelated to this module.
        # Since a2enmod/a2dismod itself succeeded above, fall back to its
        # own wording to tell whether this was a real change.
        changed = !run[:stdout].includes?("already #{state_string}")
        PluginResult.new(changed: changed, failed: false, msg: success_msg, result: success_msg)
      else
        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to set module #{name} to #{state_string}:\n#{run[:stdout]}\nMaybe the module identifier (#{identifier}) was guessed incorrectly." + "Consider setting the \"identifier\" option.",
          rc: run[:exit_code],
          stdout: run[:stdout],
          stderr: run[:stderr]
        )
      end
    end

    # Real _module_is_enabled: a plain " <identifier>" substring test on
    # `apache2ctl -M`'s stdout (apachectl as fallback control binary).
    # Returns {enabled, configcheck_failed}: a non-zero -M exit means
    # the configuration itself is broken - fatal unless
    # ignore_configcheck absorbed it, in which case the module reports
    # "not enabled" with configcheck_failed set so the caller can fall
    # back to a2enmod/a2dismod's own wording.
    private def module_is_enabled(identifier : String, name : String) : {Bool, Bool}
      result = ctl_m
      return {result[:stdout].includes?(" #{identifier}"), false} if result[:exit_code] == 0

      error_msg = "Error executing #{ctl_binary}: #{result[:stderr]}"
      unless true?(@params["ignore_configcheck"]?)
        raise ModuleError.new(error_msg)
      end

      if result[:stderr].includes?("AH00534") && name.includes?("mpm_") && true?(@params["warn_mpm_absent"]?, true)
        @warnings << "No MPM module loaded! apache2 reload AND other module actions will fail if no MPM module is loaded immediately."
      else
        @warnings << error_msg
      end
      {false, true}
    end

    private def ctl_binary : String
      probe = remote_exec("command -v apache2ctl 2>/dev/null || command -v apachectl 2>/dev/null")
      first = probe[:stdout].strip.split("\n").first?
      raise ModuleError.new("Neither of apache2ctl nor apachectl found. At least one apache control binary is necessary.") if probe[:exit_code] != 0 || !first || first.empty?
      first
    end

    private def ctl_m
      remote_exec("export LANGUAGE=C LC_ALL=C; #{ctl_binary} -M")
    end

    private def run_threaded? : Bool
      result = remote_exec("export LANGUAGE=C LC_ALL=C; #{ctl_binary} -V")
      result[:stdout] =~ /threaded: *yes/ ? true : false
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end

    class ModuleError < Exception
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::Apache2ModulePlugin.new(config)
plugin.run
