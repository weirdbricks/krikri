#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
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
    include PluginHelpers::AnsibleArgValidation

    # Live-verified against real ansible-core 2.19.11 (community.general
    # git_config) via `{{ r | to_json }}` dumps. The write path (set or
    # unset, changed, including check mode) is msg/diff/changed; the
    # converged no-op path is changed/msg - different module code paths,
    # so two orders. krikri emits no diff (real carries one on the write
    # path; the key is skipped by the reorder).
    CHANGED_KEY_ORDER = %w[msg diff changed ansible_facts failed warnings]
    UNCHANGED_KEY_ORDER = %w[changed msg ansible_facts failed warnings]

    # Real argument_spec (community.general git_config.py) - no aliases,
    # so the unsupported-params message has no parenthetical.
    SPEC = {
      "add_mode" => %w[],
      "file"     => %w[],
      "name"     => %w[],
      "repo"     => %w[],
      "scope"    => %w[],
      "state"    => %w[],
      "value"    => %w[],
    }

    EXTRA_BIN_DIRS = %w[/sbin /usr/sbin /bin /usr/bin]
    @searched_paths = ""
    @git_path = "git"

    def execute : PluginResult
      if error = validate_and_locate_git
        return error
      end

      name = @params["name"]
      state = @params["state"]? || "present"
      unset = state == "absent"
      value = @params["value"]? || ""
      add_mode = @params["add_mode"]? || "replace-all"
      scope = @params["scope"]?
      check_mode = true?(@params["_ansible_check_mode"]?)

      # Real main()'s own post-setup guard: the spec's required_if only
      # fires on a MISSING value key, so an empty-string value reaches
      # this check instead.
      if !unset && value.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "If state=present, a value must be specified. Use the community.general.git_config_info module to read a config value.")
      end

      effective_scope = scope || "system"
      cwd = (effective_scope == "local" ? @params["repo"] : "/").as(String)
      base_args = build_base_args(effective_scope)

      old_values, has_out, list_error = read_current_values(base_args, cwd, name)
      return list_error if list_error

      noop = already_converged?(unset, has_out, old_values, value, add_mode)
      return noop if noop

      return PluginResult.new(changed: true, failed: false, msg: "setting changed (check mode)", key_order: CHANGED_KEY_ORDER) if check_mode

      apply_setting(base_args, cwd, name, value, unset, add_mode)
    end

    # get_bin_path('git', required=True) runs right after module
    # validation, before any config work.
    private def validate_and_locate_git : PluginResult?
      if error = validate_arguments
        return error
      end

      unless found = find_binary("git")
        return PluginResult.new(changed: false, failed: true,
          msg: PluginHelpers::GetBinPath.missing_executable_error("git", @searched_paths))
      end
      @git_path = found
      nil
    end

    private def already_converged?(unset : Bool, has_out : Bool, old_values : Array(String), value : String, add_mode : String) : PluginResult?
      return PluginResult.new(changed: false, failed: false, msg: "no setting to unset", key_order: UNCHANGED_KEY_ORDER) if unset && !has_out
      return nil if unset

      if old_values.includes?(value) && (old_values.size == 1 || add_mode == "add")
        # Real's no-op path passes msg='' to exit_json explicitly, so the
        # result keeps an EMPTY msg key (msg | default('none') shows ''
        # there, not 'none' - live-verified GC9b).
        return PluginResult.new(changed: false, failed: false, msg: "", include_empty_msg: true, key_order: UNCHANGED_KEY_ORDER)
      end
      nil
    end

    # Real AnsibleModule setup surface, in the validator's errors[0]
    # order (arg_spec.py: required -> choices -> required_if ->
    # unsupported). No bool/int params in the spec, so no type checks.
    private def validate_arguments : PluginResult?
      return missing_required_error(["name"]) unless @params["name"]?

      if error = validate_choice_params
        return error
      end

      if error = validate_required_if_params
        return error
      end

      if unsupported = unsupported_param_keys(@params, SPEC)
        unless unsupported.empty?
          return unsupported_params_error("community.general.git_config", unsupported, SPEC)
        end
      end

      nil
    end

    private def validate_choice_params : PluginResult?
      if add_mode = @params["add_mode"]?
        unless %w[add replace-all].includes?(add_mode)
          return choices_error("add_mode", %w[add replace-all], add_mode)
        end
      end

      if scope = @params["scope"]?
        unless %w[file local global system].includes?(scope)
          return choices_error("scope", %w[file local global system], scope)
        end
      end

      state = @params["state"]? || "present"
      unless %w[present absent].includes?(state)
        return choices_error("state", %w[present absent], state)
      end
      nil
    end

    # required_if, declaration order; only a MISSING key fails.
    private def validate_required_if_params : PluginResult?
      scope = @params["scope"]?
      state = @params["state"]? || "present"
      if scope == "local" && !@params["repo"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "scope is local but all of the following are missing: repo")
      end
      if scope == "file" && !@params["file"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "scope is file but all of the following are missing: file")
      end
      if state == "present" && !@params["value"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is present but all of the following are missing: value")
      end
      nil
    end

    private def build_base_args(effective_scope : String) : Array(String)
      # Real's get_bin_path resolved the binary to an absolute path
      # before any command ran, and its failure results carry the RESOLVED
      # args - so the array-typed cmd field shows "/usr/bin/git", not the
      # bare name.
      base_args = [@git_path, "config", "--includes"]
      if effective_scope == "file"
        base_args << "-f" << @params["file"].as(String)
      else
        base_args << "--#{effective_scope}"
      end
      base_args
    end

    private def read_current_values(base_args : Array(String), cwd : String, name : String) : {Array(String), Bool, PluginResult?}
      list_args = base_args + ["--get-all", name]
      list_cmd = list_args.map { |arg| shell_quote(arg) }.join(" ")
      list_result = remote_exec("cd #{shell_quote(cwd)} && #{list_cmd}")

      if list_result[:exit_code] >= 2
        # Real: fail_json(rc=rc, msg=err, cmd=' '.join(list_args)) - the
        # LIST failure's cmd is a space-joined STRING (vs the set
        # failure's array, below).
        return {[] of String, false, PluginResult.new(changed: false, failed: true,
          msg: list_result[:stderr], cmd: list_args.join(' '), rc: list_result[:exit_code])}
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
        # Real: fail_json(rc=rc, msg=err, cmd=set_args) - the SET failure's
        # cmd is the raw args LIST (rendered as a JSON array in the
        # result), unlike the list-command failure's joined string.
        return PluginResult.new(changed: false, failed: true, msg: set_result[:stderr],
          cmd: set_args, rc: set_result[:exit_code])
      end

      PluginResult.new(changed: true, failed: false, msg: "setting changed", key_order: CHANGED_KEY_ORDER)
    end

    private def find_binary(name : String) : String?
      script = <<-SH
        found=""
        for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
          if [ -z "$found" ] && [ -x "$d/#{name}" ]; then found="$d/#{name}"; fi
        done
        searched=""
        for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
          case ":$searched:" in *":$d:"*) ;; *) searched="${searched:+$searched:}$d" ;; esac
        done
        printf '%s\\n%s' "$found" "$searched"
        SH

      result = remote_exec(script)
      found, _, searched = result[:stdout].to_s.partition("\n")
      found = found.strip
      searched = searched.strip
      @searched_paths = searched
      found.empty? ? nil : found
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::GitConfigPlugin.new(config)
plugin.run
