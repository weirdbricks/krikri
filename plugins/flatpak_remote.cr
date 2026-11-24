#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/run_command_failure"

module Krikri
  # community.general.flatpak_remote - manage flatpak repository remotes
  # through the `flatpak` CLI, a native reimplementation of the Ansible
  # module's control flow.
  #
  # Before this plugin the task was dropped as an unimplemented plugin
  # (issue #1774, alvistack.firefox): real ansible RUNS the module even in
  # check mode - its queries always execute - and fails the task with
  # "Executable 'flatpak' was not found on the system." on a host without
  # flatpak, stopping the play (rc=2) where krikri skipped every loop item
  # and ran on (rc=4).
  #
  # Module quirks kept as-is:
  #   - get_bin_path(executable, None) is NOT required; a missing binary is
  #     a fail_json with the module's own wording, not get_bin_path's.
  #   - remote-add/remote-delete/remote-modify are check-mode noops, but
  #     remote-list (the existence/enabled queries) always runs for real.
  #   - the result dict keeps command/rc/stdout/stderr from the LAST
  #     command (queries included), exactly like the module's global
  #     `result`.
  class FlatpakRemotePlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real's argument_spec (name => aliases), sorted for the
    # unsupported-params wording.
    SPEC = {
      "enabled"         => [] of String,
      "executable"      => [] of String,
      "flatpakrepo_url" => [] of String,
      "method"          => [] of String,
      "name"            => [] of String,
      "state"           => [] of String,
    }

    METHOD_CHOICES = %w[user system]
    STATE_CHOICES  = %w[absent present]

    # The module's global `result` dict: _flatpak_command writes `command`
    # first, then run_command's rc/stdout/stderr, and exit_json re-emits
    # that insertion order.
    @command : String? = nil
    @rc = 0
    @stdout : String? = nil
    @stderr : String? = nil
    @changed = false

    private class CommandFailure < Exception
      getter result : PluginResult

      def initialize(@result : PluginResult)
        super("flatpak command failed")
      end
    end

    protected def bool_params : Array(String)
      %w[enabled]
    end

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      executable = @params["executable"]? || "flatpak"
      binary = resolve_binary(executable)
      unless binary
        return PluginResult.new(changed: false, failed: true,
          msg: "Executable '#{executable}' was not found on the system.")
      end

      apply_state(binary)
      success_result
    rescue ex : CommandFailure
      ex.result
    end

    # AnsibleModule init order: unsupported parameters, then type
    # conversion, then required arguments, then choices.
    private def validate_arguments : PluginResult?
      if err = validate_unsupported
        return err
      end
      validate_bool_params!

      return missing_required_error(["name"]) unless @params["name"]?

      method = @params["method"]? || "system"
      return choices_error("method", METHOD_CHOICES, method) unless METHOD_CHOICES.includes?(method)

      state = @params["state"]? || "present"
      return choices_error("state", STATE_CHOICES, state) unless STATE_CHOICES.includes?(state)

      nil
    end

    private def apply_state(binary : String) : Nil
      name = @params["name"].to_s
      method = @params["method"]? || "system"
      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)

      remote_already_exists = remote_exists(binary, name, method)
      add_or_remove(binary, name, state, method, check_mode, remote_already_exists)
      update_enabled(binary, name, method) if state == "present"
    end

    private def add_or_remove(binary, name, state, method, check_mode, remote_already_exists) : Nil
      if state == "present" && !remote_already_exists
        add_remote(binary, name, @params["flatpakrepo_url"]? || "", method, check_mode)
      elsif state == "absent" && remote_already_exists
        remove_remote(binary, name, method, check_mode)
      end
    end

    private def update_enabled(binary, name, method) : Nil
      enabled = true?(@params["enabled"]?, default: true)
      check_mode = true?(@params["_ansible_check_mode"]?)
      remote_already_enabled = remote_enabled(binary, name, method)

      if enabled && !remote_already_enabled
        enable_remote(binary, name, method, check_mode)
      end
      if !enabled && remote_already_enabled
        disable_remote(binary, name, method, check_mode)
      end
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      return nil if unsupported.empty?
      unsupported_params_error("community.general.flatpak_remote", unsupported, SPEC)
    end

    private def add_remote(binary, name, flatpakrepo_url, method, check_mode) : Nil
      flatpak_command([binary, "remote-add", "--#{method}", name, flatpakrepo_url], check_mode)
      @changed = true
    end

    private def remove_remote(binary, name, method, check_mode) : Nil
      flatpak_command([binary, "remote-delete", "--#{method}", "--force", name], check_mode)
      @changed = true
    end

    private def enable_remote(binary, name, method, check_mode) : Nil
      flatpak_command([binary, "remote-modify", "--enable", "--#{method}", name], check_mode)
      @changed = true
    end

    private def disable_remote(binary, name, method, check_mode) : Nil
      flatpak_command([binary, "remote-modify", "--disable", "--#{method}", name], check_mode)
      @changed = true
    end

    # The module's remote_exists: the remote-list query always runs (also
    # in check mode), and the first whitespace-separated column is the
    # remote name.
    private def remote_exists(binary, name, method) : Bool
      output = flatpak_command([binary, "remote-list", "--show-disabled", "--#{method}"], false)
      output.each_line.any? do |line|
        listed = line.split(/\s+/).reject(&.empty?)
        !listed.empty? && listed[0] == name
      end
    end

    # remote_enabled: a listed remote is enabled unless its options column
    # (the second one) names "disabled".
    private def remote_enabled(binary, name, method) : Bool
      output = flatpak_command([binary, "remote-list", "--show-disabled", "--#{method}"], false)
      output.each_line.each do |line|
        listed = line.split(/\s+/).reject(&.empty?)
        next if listed.empty?
        next unless listed[0] == name
        return listed.size == 1 || !listed[1].split(",").includes?("disabled")
      end
      false
    end

    # _flatpak_command: `noop` is the module's check-mode branch - it
    # records the command and a zero rc without executing anything.
    private def flatpak_command(argv : Array(String), noop : Bool) : String
      @command = argv.join(" ")
      if noop
        @rc = 0
        return ""
      end

      cmd = argv.map { |arg| Process.quote(arg) }.join(" ")
      result = remote_exec(cmd)
      stdout = result[:stdout]
      stderr = result[:stderr]
      @rc = result[:exit_code]
      @stdout = stdout
      @stderr = stderr
      if @rc != 0
        raise CommandFailure.new(
          PluginHelpers::RunCommandFailure.nonzero_exit(cmd, @rc, stdout, stderr))
      end
      stdout
    end

    private def success_result : PluginResult
      result = PluginResult.new(changed: @changed, failed: false)
      result.key_order = %w[changed command rc stdout stderr]
      if command = @command
        result.extra["command"] = JSON::Any.new(command)
        result.extra["rc"] = JSON::Any.new(@rc.to_i64)
      end
      if stdout = @stdout
        result.extra["stdout"] = JSON::Any.new(stdout)
      end
      if stderr = @stderr
        result.extra["stderr"] = JSON::Any.new(stderr)
      end
      result
    end

    # AnsibleModule.get_bin_path(executable, None): os.path.join each
    # search directory with the arg - an absolute arg therefore resolves
    # to itself, a bare name to <dir>/<name>. Path entries come first,
    # then the existing sbin dirs an Ansible module appends.
    private def resolve_binary(executable : String) : String?
      # PATH is split by the shell's own word splitting (IFS=:), not by
      # an external `tr`: a pinned PATH without /usr/bin must still
      # resolve a binary that IS on it (real shell-splits in Python).
      script = <<-SH
        exe=#{shell_single_quote(executable)}
        found=""
        set -f
        oldifs=$IFS
        IFS=:
        for d in $PATH /sbin /usr/sbin /usr/local/sbin; do
          [ -n "$d" ] || continue
          case "$exe" in
            /*) candidate="$exe" ;;
            *) candidate="$d/$exe" ;;
          esac
          if [ -z "$found" ] && [ -f "$candidate" ] && [ -x "$candidate" ]; then found="$candidate"; fi
        done
        IFS=$oldifs
        printf '%s' "$found"
        SH
      found = remote_exec(script)[:stdout].to_s.strip
      found.empty? ? nil : found
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::FlatpakRemotePlugin.new(config)
plugin.run
