#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # git_config plugin - reads/writes git configuration via `git config`.
  # Compatible with (a subset of) Ansible's community.general.git_config
  # module.
  #
  # Parameters:
  #   name (required): the setting name (e.g. "user.email")
  #   value: the value to set (required when state: present)
  #   state: present (default) / absent
  #   scope: file / local / global / system (default: system, matching
  #     real Ansible's own determine_scope - NOT git's own default of
  #     "local" when no --scope flag is passed)
  #   repo: required when scope: local - the repo to run `git config` in
  #   file: required when scope: file - path to an ad-hoc config file
  #   add_mode: add / replace-all (default: replace-all)
  class GitConfigPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      state = @params["state"]? || "present"
      unset = state == "absent"
      value = @params["value"]? || ""
      add_mode = @params["add_mode"]? || "replace-all"
      scope = @params["scope"]?
      check_mode = is_true?(@params["check_mode"]?)

      validation_error = validate_params(unset, value, scope)
      return validation_error if validation_error

      effective_scope = scope || "system"
      cwd = (effective_scope == "local" ? @params["repo"] : "/").as(String)
      base_args = build_base_args(effective_scope)

      old_values, has_out, list_error = read_current_values(base_args, cwd, name)
      return list_error if list_error

      noop = already_converged?(unset, has_out, old_values, value, add_mode)
      return noop if noop

      return PluginResult.new(changed: true, failed: false, msg: "setting changed (check mode)") if check_mode

      apply_setting(base_args, cwd, name, value, unset, add_mode)
    end

    private def already_converged?(unset : Bool, has_out : Bool, old_values : Array(String), value : String, add_mode : String) : PluginResult?
      return PluginResult.new(changed: false, failed: false, msg: "no setting to unset") if unset && !has_out
      return nil if unset

      if old_values.includes?(value) && (old_values.size == 1 || add_mode == "add")
        return PluginResult.new(changed: false, failed: false, msg: "")
      end
      nil
    end

    private def validate_params(unset : Bool, value : String, scope : String?) : PluginResult?
      if !unset && value.empty?
        return PluginResult.new(changed: false, failed: true, msg: "If state=present, a value must be specified.")
      end
      if scope == "local" && !@params["repo"]?
        return missing_param("repo (required when scope: local)")
      end
      if scope == "file" && !@params["file"]?
        return missing_param("file (required when scope: file)")
      end
      nil
    end

    private def build_base_args(effective_scope : String) : Array(String)
      base_args = ["git", "config", "--includes"]
      if effective_scope == "file"
        base_args << "-f" << @params["file"].as(String)
      else
        base_args << "--#{effective_scope}"
      end
      base_args
    end

    private def read_current_values(base_args : Array(String), cwd : String, name : String) : {Array(String), Bool, PluginResult?}
      list_cmd = (base_args + ["--get-all", name]).map { |arg| shell_quote(arg) }.join(" ")
      list_result = remote_exec("cd #{shell_quote(cwd)} && #{list_cmd}")

      if list_result[:exit_code] >= 2
        return {[] of String, false, PluginResult.new(changed: false, failed: true, msg: list_result[:stderr])}
      end

      old_values = list_result[:stdout].rstrip.split('\n').reject(&.empty?)
      {old_values, !list_result[:stdout].empty?, nil}
    end

    private def apply_setting(base_args : Array(String), cwd : String, name : String, value : String, unset : Bool, add_mode : String) : PluginResult
      set_args = base_args.dup
      if unset
        set_args << "--unset-all" << name
      else
        set_args << "--#{add_mode}" << name << value
      end
      set_cmd = set_args.map { |arg| shell_quote(arg) }.join(" ")

      set_result = remote_exec("cd #{shell_quote(cwd)} && #{set_cmd}")
      unless set_result[:stderr].empty?
        return PluginResult.new(changed: false, failed: true, msg: set_result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "setting changed")
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::GitConfigPlugin.new(config)
plugin.run
