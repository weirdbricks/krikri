#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/run_command_failure"

module Krikri
  # community.general.flatpak - install/update/uninstall flatpaks through
  # the `flatpak` CLI, a native reimplementation of the Ansible module's
  # control flow.
  #
  # Ported for issue #1774 (alvistack.firefox), whose "flatpak install"
  # task krikri dropped as an unimplemented plugin with the "flatpak
  # remote-add" task above it. Real runs both modules (check mode
  # included - the queries always execute) and fails them on a host with
  # no flatpak binary with "Executable 'flatpak' was not found on the
  # system." where krikri skipped (rc=4).
  #
  # Module quirks kept as-is:
  #   - get_bin_path(executable, None) is NOT required; a missing binary
  #     is the module's own fail_json wording.
  #   - install/update/uninstall are check-mode noops, but `flatpak
  #     list` (name existence, installed-name matching) always runs.
  #   - a name may be an app id, a .flatpakref URL or a local path run
  #     through _parse_flatpak_name's id detection.
  #   - flatpak < 1.1.3 needs -y instead of --noninteractive, decided by
  #     the `flatpak --version` probe on every operation.
  class FlatpakPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real's argument_spec (name => aliases), sorted for the
    # unsupported-params wording.
    SPEC = {
      "executable"      => [] of String,
      "method"          => [] of String,
      "name"            => [] of String,
      "no_dependencies" => [] of String,
      "remote"          => [] of String,
      "state"           => [] of String,
    }

    METHOD_CHOICES = %w[user system]
    STATE_CHOICES  = %w[absent present latest]

    OUTDATED_FLATPAK_VERSION_ERROR_MESSAGE = "Unknown option --columns=application"

    # The module's global `result` dict (see flatpak_remote.cr's note).
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

    private class NameMatchFailure < Exception
      getter result : PluginResult

      def initialize(@result : PluginResult)
        super("could not match installed flatpaks")
      end
    end

    protected def bool_params : Array(String)
      %w[no_dependencies]
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
    rescue ex : NameMatchFailure
      ex.result
    end

    # AnsibleModule init order: unsupported parameters, then type
    # conversion, then required arguments, then choices.
    private def validate_arguments : PluginResult?
      if err = validate_unsupported
        return err
      end
      validate_bool_params!

      return missing_required_error(["name"]) unless @params.has_key?("name")

      method = @params["method"]? || "system"
      return choices_error("method", METHOD_CHOICES, method) unless METHOD_CHOICES.includes?(method)

      state = @params["state"]? || "present"
      return choices_error("state", STATE_CHOICES, state) unless STATE_CHOICES.includes?(state)

      nil
    end

    private def apply_state(binary : String) : Nil
      method = @params["method"]? || "system"
      state = @params["state"]? || "present"
      names = parse_names(@params["name"].to_s)
      remote = @params["remote"]? || "flathub"
      no_dependencies = true?(@params["no_dependencies"]?)
      check_mode = true?(@params["_ansible_check_mode"]?)

      installed, not_installed = flatpak_exists(binary, names, method)

      if state == "absent" && !installed.empty?
        uninstall_flat(binary, installed, method, check_mode)
        return
      end

      if state == "latest" && !installed.empty?
        update_flat(binary, installed, method, no_dependencies, check_mode)
      end

      if (state == "present" || state == "latest") && !not_installed.empty?
        install_flat(binary, remote, not_installed, method, no_dependencies, check_mode)
      end
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      return nil if unsupported.empty?
      unsupported_params_error("community.general.flatpak", unsupported, SPEC)
    end

    private def install_flat(binary, remote, names, method, no_dependencies, check_mode) : Nil
      uri_names = [] of String
      id_names = [] of String
      names.each do |name|
        if name.starts_with?("http://") || name.starts_with?("https://")
          uri_names << name
        else
          id_names << name
        end
      end

      base_command = [binary, "install", "--#{method}"]
      base_command << noninteractive_flag(binary)
      base_command << "--no-deps" if no_dependencies

      flatpak_command(base_command + uri_names, check_mode) unless uri_names.empty?
      flatpak_command(base_command + [remote] + id_names, check_mode) unless id_names.empty?
      @changed = true
    end

    private def update_flat(binary, names, method, no_dependencies, check_mode) : Nil
      installed_names = names.map { |name| match_installed_flat_name(binary, name, method) }
      command = [binary, "update", "--#{method}"]
      command << noninteractive_flag(binary)
      command << "--no-deps" if no_dependencies
      command += installed_names
      stdout = flatpak_command(command, check_mode)
      @changed = check_mode ? true : !stdout.includes?("Nothing to do.")
    end

    private def uninstall_flat(binary, names, method, check_mode) : Nil
      installed_names = names.map { |name| match_installed_flat_name(binary, name, method) }
      command = [binary, "uninstall", noninteractive_flag(binary), "--#{method}"]
      command += installed_names
      flatpak_command(command, check_mode)
      @changed = true
    end

    # The module's flatpak_exists: the parsed app name is looked for
    # case-insensitively in the WHOLE `flatpak list` output, not line by
    # line.
    private def flatpak_exists(binary, names, method) : {Array(String), Array(String)}
      output = flatpak_command([binary, "list", "--#{method}"], false)
      haystack = output.downcase
      installed = [] of String
      not_installed = [] of String
      names.each do |name|
        if haystack.includes?(parse_flatpak_name(name).downcase)
          installed << name
        else
          not_installed << name
        end
      end
      {installed, not_installed}
    end

    private def match_installed_flat_name(binary, name, method) : String
      parsed_name = parse_flatpak_name(name)
      command = [binary, "list", "--#{method}", "--app", "--columns=application"]
      flatpak_command(command, false, ignore_failure: true)

      matched = if @rc != 0 && @stderr.to_s.includes?(OUTDATED_FLATPAK_VERSION_ERROR_MESSAGE)
                  match_flat_using_flatpak_column_feature(binary, parsed_name, method)
                else
                  match_flat_using_outdated_flatpak_format(binary, parsed_name, method)
                end

      return matched if matched

      raise NameMatchFailure.new(failure_result(
        "Flatpak removal failed: Could not match any installed flatpaks to the name " \
        "`#{parsed_name}`. If you used a URL, try using the reverse DNS name of the flatpak"))
    end

    private def match_flat_using_outdated_flatpak_format(binary, parsed_name, method) : String?
      output = flatpak_command([binary, "list", "--#{method}", "--app", "--columns=application"], false)
      output.each_line.each do |row|
        return row if parsed_name.downcase == row.downcase
      end
      nil
    end

    private def match_flat_using_flatpak_column_feature(binary, parsed_name, method) : String?
      output = flatpak_command([binary, "list", "--#{method}", "--app"], false)
      wanted = parsed_name.downcase
      output.each_line.each do |row|
        return row.split(/\s+/).reject(&.empty?).first? if row.downcase.includes?(wanted)
      end
      nil
    end

    # flatpak < 1.1.3 accepts -y but not --noninteractive; the module
    # probes `flatpak --version` on every install/update/uninstall.
    private def noninteractive_flag(binary) : String
      output = flatpak_command([binary, "--version"], false)
      version = output.split[1]?
      return "--noninteractive" unless version
      version_older_than?(version, "1.1.3") ? "-y" : "--noninteractive"
    end

    private def version_older_than?(version : String, other : String) : Bool
      left = version.split('.')
      right = other.split('.')
      [left.size, right.size].max.times do |index|
        a = left[index]?
        b = right[index]?
        return true if a.nil?
        return false if b.nil?
        a_int = a.to_i?
        b_int = b.to_i?
        if a_int && b_int
          return true if a_int < b_int
          return false if a_int > b_int
        else
          return true if a < b
          return false if a > b
        end
      end
      false
    end

    # _is_flatpak_id: a dotted, reverse-DNS-looking id - a lowercase
    # domain first section, alphanumeric sections after it.
    private def flatpak_id?(part : String) : Bool
      return false unless part.includes?('.')
      sections = part.split('.')
      return false if sections.size < 2
      domain = sections[0]
      return false if domain.downcase != domain
      return false unless domain.each_char.any?(&.letter?)
      sections[1..].all? do |section|
        !section.empty? && section.each_char.all? { |char| char.letter? || char.number? }
      end
    end

    # _parse_flatpak_name: a URL's last path segment minus its
    # extensions, else the first path component that looks like an app
    # id, else the name unchanged.
    private def parse_flatpak_name(name : String) : String
      if name.starts_with?("http://") || name.starts_with?("https://")
        path = name.sub(/\Ahttps?:\/\//, "").split(/[?#]/, 2).first? || ""
        file_name = path.split('/').last? || ""
        parts = file_name.split('.')
        return parts[0...-1].join('.')
      end

      name.split('/').each do |part|
        return part if flatpak_id?(part)
      end
      name
    end

    private def parse_names(raw : String) : Array(String)
      parsed = JSON.parse(raw) rescue nil
      if array = parsed.try(&.as_a?)
        return array.map { |entry| entry.as_s? || entry.raw.to_s }
      end
      if text = parsed.try(&.as_s?)
        return text.split(',')
      end
      raw.split(',')
    end

    # _flatpak_command: `noop` is the module's check-mode branch, which
    # records the command and a zero rc without executing it.
    private def flatpak_command(argv : Array(String), noop : Bool, ignore_failure : Bool = false) : String
      @command = argv.join(" ")
      if noop
        @rc = 0
        return ""
      end

      # real's run_command_environ_update (LANGUAGE/LC_ALL) rides Popen's
      # env, not the argv - the failure's `cmd` must not show it. A shell
      # assignment prefix, not `env LANGUAGE=...`, because a pinned PATH
      # need not contain /usr/bin/env.
      reported = argv.map { |arg| Process.quote(arg) }.join(' ')
      result = remote_exec("LANGUAGE=C LC_ALL=C #{reported}")
      stdout = result[:stdout]
      stderr = result[:stderr]
      @rc = result[:exit_code]
      @stdout = stdout
      @stderr = stderr
      if @rc != 0 && !ignore_failure
        raise CommandFailure.new(
          PluginHelpers::RunCommandFailure.nonzero_exit(reported, @rc, stdout, stderr))
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

    # The module's fail_json(**result) after it staged `msg` into result
    # (the failure carries the last command's keys too).
    private def failure_result(msg : String) : PluginResult
      result = PluginResult.new(changed: @changed, failed: true, msg: msg)
      result.key_order = %w[changed command rc stdout stderr msg]
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

    # See flatpak_remote.cr's resolve_binary: AnsibleModule.get_bin_path
    # with required=False, so a missing binary is the module's own
    # failure, not get_bin_path's.
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
plugin = Krikri::FlatpakPlugin.new(config)
plugin.run
