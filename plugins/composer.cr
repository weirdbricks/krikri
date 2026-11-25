#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_splitlines"
require "../src/krikri/plugin_helpers/composer"
require "../src/krikri/plugin_helpers/get_bin_path"

module Krikri
  # community.general.composer - runs the target's PHP composer for
  # dependency installs/updates, a native reimplementation of the Ansible
  # module's control flow.
  #
  # Ported for issue #1797 (marsante.ansible_role_medshakeehr): the role's
  # "Composer update on /var/www/ehr"/"Composer upgrade on ..." tasks were
  # dropped as an unimplemented plugin and reported `skipping:` with
  # exit 4, where real Ansible RUNS the module - under --check too, where
  # composer's update/require family answers `ok` for an already
  # converged project. Everything below the composer tasks then diverged
  # on the krikri host (vendor/ never installed, so the role's own
  # install.php task failed and the tasks after it never converged).
  #
  # Module quirks kept as-is:
  #   - check mode appends --dry-run, but only when the command's own
  #     `composer help <command> --format=json` advertises it; otherwise
  #     the module exits with skipped=True and "command '<c>' does not
  #     support check mode, skipping" instead of running anything.
  #   - the option table is what composer's help output advertises:
  #     unknown options are never passed, and apcu_autoloader never adds
  #     one (see PluginHelpers::Composer::OPTION_PARAMS' typo note).
  #   - changed is decided from the output text alone (has_changed), not
  #     from composer's exit code.
  #   - a failed composer run reports msg=<stderr collapsed> and
  #     stdout=<raw stderr> - the module's own `stdout=err` argument.
  class ComposerPlugin < BasePlugin
    # AnsibleModule.run_command pins the locale for every exec the module
    # makes, so composer's own messages stay in the language the
    # has_changed markers are written in.
    LOCALE_ENV = "LANGUAGE=C LC_ALL=C LC_MESSAGES=C "

    # get_bin_path's opt_dirs argument for both binaries: searched (and
    # quoted in the failure message) before the module process's $PATH.
    OPT_DIR = "/usr/local/bin"

    # Registered key order of the module's run_command failure
    # (live-verified against 2.21.6 through `{{ r | to_json }}`).
    FAILURE_KEY_ORDER = ["changed", "failed", "exception", "msg", "stdout", "stdout_lines"]

    def execute : PluginResult
      command = @params["command"]?.presence || "install"

      if failure = argument_failure(command)
        return failure
      end

      available = available_options(command)
      return available if available.is_a?(PluginResult)

      options = options_for(available)
      if true?(@params["_ansible_check_mode"]?)
        # Only a command whose help output advertises --dry-run is run in
        # check mode; the rest are answered with a skip.
        return check_mode_skip(command) unless available.includes?("dry-run")
        options << "--dry-run"
      end

      run = composer_command([command], Shell.shlex_split(@params["arguments"]? || ""), options)
      return run if run.is_a?(PluginResult)
      return run_failure(run) if run[:exit_code] != 0

      success_result(run)
    end

    # The module's own argument checks, in their real order: AnsibleModule
    # init's required_if fails before the module body runs, and main()'s
    # whitespace check precedes the binary lookups.
    private def argument_failure(command : String) : PluginResult?
      # required_if=[("global_command", False, ["working_dir"])]
      if !true?(@params["global_command"]?) && @params["working_dir"]?.presence.nil?
        return PluginResult.new(changed: false, failed: true,
          msg: "global_command is False but all of the following are missing: working_dir")
      end

      if command.matches?(/\s/)
        return PluginResult.new(changed: false, failed: true,
          msg: "Use the 'arguments' param for passing arguments with the 'command'")
      end

      nil
    end

    # The default options, then the option-backed params - but only those
    # the command's help output advertises, like the module's own
    # `option in available_options` gate.
    private def options_for(available : Array(String)) : Array(String)
      options = [] of String
      PluginHelpers::Composer::DEFAULT_OPTIONS.each do |name|
        options << "--#{name}" if available.includes?(name)
      end
      PluginHelpers::Composer::OPTION_PARAMS.each do |param, name|
        next unless available.includes?(name)
        options << "--#{name}" if true?(@params[param]?, PluginHelpers::Composer.param_default_true?(param))
      end
      options
    end

    private def check_mode_skip(command : String) : PluginResult
      PluginResult.new(changed: false, failed: false,
        msg: "command '#{command}' does not support check mode, skipping", skipped: true)
    end

    # fail_json(msg=<stderr collapsed>, stdout=<raw stderr>): the module
    # passes the stderr text through `stdout` unused, and the controller
    # derives stdout_lines from it.
    private def run_failure(run : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: PluginHelpers::Composer.parse_out(run[:stderr]),
        stdout: run[:stderr], stdout_lines: PluginHelpers::AnsibleSplitlines.split(run[:stderr]),
        key_order: FAILURE_KEY_ORDER, include_empty_msg: true)
    end

    # Composer > 1.0.0-alpha9 writes its notifications to stderr, so
    # has_changed reads both streams.
    private def success_result(run : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      combined = run[:stdout] + run[:stderr]
      output = PluginHelpers::Composer.parse_out(combined)
      PluginResult.new(changed: PluginHelpers::Composer.changed?(output), failed: false,
        msg: output, stdout: combined, stdout_lines: PluginHelpers::AnsibleSplitlines.split(combined),
        include_empty_msg: true)
    end

    # get_available_options(): the command's own options, read from
    # `composer help <command> --format=json`, so an option composer does
    # not know is never passed. A non-zero help run fails the task with
    # composer's collapsed stderr - which, on a host whose composer has no
    # --format=json, is the module's real failure too.
    private def available_options(command : String) : Array(String) | PluginResult
      help = composer_command(["help", command], ["--no-interaction", "--format=json"], [] of String)
      return help if help.is_a?(PluginResult)
      if help[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: PluginHelpers::Composer.parse_out(help[:stderr]), include_empty_msg: true)
      end

      definition = JSON.parse(help[:stdout])["definition"]?
      options = definition.try(&.["options"]?)
      options.try(&.as_h?).try(&.keys) || [] of String
    end

    # composer_command(): build [php, composer, <global>, <command>,
    # <options>, <arguments>] and run it. Both binaries are resolved on
    # every call, exactly like the module's get_bin_path calls (required,
    # with OPT_DIR in the search list) - so the missing-binary failure
    # carries composer's own message and its own search order.
    private def composer_command(command : Array(String), arguments : Array(String), options : Array(String)) : NamedTuple(exit_code: Int32, stdout: String, stderr: String) | PluginResult
      argv = [] of String

      # `executable` is aliased to `php_path` in the module's argument_spec;
      # krikri hands task params through by their written name, so both
      # spellings have to be read here.
      php = @params["executable"]?.presence || @params["php_path"]?.presence || resolve_binary("php")
      return php if php.is_a?(PluginResult)
      argv << php

      composer = @params["composer_executable"]?.presence || resolve_binary("composer")
      return composer if composer.is_a?(PluginResult)
      argv << composer

      options = options.dup
      if true?(@params["global_command"]?)
        # A global run is `composer global <command>`: no --working-dir.
        argv << "global"
      else
        options.concat(PluginHelpers::Composer.working_dir_options(@params["working_dir"]? || ""))
      end

      argv.concat(command)
      argv.concat(options)
      argv.concat(arguments)
      remote_exec(LOCALE_ENV + argv.map { |arg| Shell.quote_arg(arg) }.join(" "))
    end

    private def resolve_binary(name : String) : String | PluginResult
      found, searched = search_binary(name)
      return found if found
      PluginResult.new(changed: false, failed: true,
        msg: PluginHelpers::GetBinPath.missing_executable_error(name, searched))
    end

    # get_bin_path(): OPT_DIR (when it exists), then every $PATH entry,
    # then the extra sbin dirs not already listed. Duplicates and empty
    # $PATH entries are kept, because the failure message quotes the list
    # it searched. Probed over the connection rather than locally, since
    # the module's own $PATH is the target's.
    private def search_binary(name : String) : Tuple(String?, String)
      script = <<-SH
        searched=""
        sep=""
        found=""
        add() {
          d="$1"
          searched="${searched}${sep}$d"
          sep=":"
          if [ -z "$found" ] && [ -n "$d" ] && [ -f "$d/#{name}" ] && [ -x "$d/#{name}" ]; then
            found="$d/#{name}"
          fi
        }
        if [ -d #{OPT_DIR} ]; then add #{OPT_DIR}; fi
        old_ifs="$IFS"
        IFS=":"
        for d in $PATH; do add "$d"; done
        IFS="$old_ifs"
        for d in /sbin /usr/sbin /usr/local/sbin; do
          case ":$searched:" in
            *":$d:"*) ;;
            *) if [ -d "$d" ]; then add "$d"; fi ;;
          esac
        done
        printf 'searched=%s\n' "$searched"
        printf 'found=%s\n' "$found"
        SH

      searched = ""
      found = ""
      remote_exec(script)[:stdout].to_s.each_line do |line|
        key, _, value = line.strip.partition("=")
        searched = value if key == "searched"
        found = value if key == "found"
      end
      {found.empty? ? nil : found, searched}
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ComposerPlugin.new(config)
plugin.run
