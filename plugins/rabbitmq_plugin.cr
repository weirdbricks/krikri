#!/usr/bin/env crystal
# community.rabbitmq.rabbitmq_plugin - manages RabbitMQ plugin state via
# `rabbitmq-plugins`. Behavior matched to community.rabbitmq's rabbitmq_plugin
# module (round 196: mrlesmithjr.rabbitmq uses it; previously unavailable
# → rc=4 "unavailable modules" where Ansible rc=0'd).
#
# The module's argument is `names` (a comma-separated string); `name` is the
# same argument under its alias.
#
# Idempotency: Ansible module checks `rabbitmq-plugins list -E -m` (all
# enabled plugins, minimal output - bare names, one per line) for the
# plugin's name as an exact line match before doing anything.
#
# Every rabbitmq-plugins call goes through run_command(check_rc=True), so a
# non-zero rc is basic.py's own failure rather than a module-authored message:
# msg is the bare rstripped stderr, and cmd/rc/stdout/stderr plus the
# controller-derived *_lines ride along. A successful task returns only
# changed/enabled/disabled - the module exits through exit_json, which adds no
# msg.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/get_bin_path"

module Krikri
  class RabbitmqPluginPlugin < BasePlugin
    def execute : PluginResult
      raw_names = @params["names"]? || @params["name"]?
      unless raw_names
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: names")
      end
      # names.split(',') never trims: a playbook writing "a, b" asks for the
      # plugin " b", exactly as the Ansible module does.
      plugins = raw_names.split(",")
      failure = param_failure
      return failure if failure

      resolved = plugin_bin
      bin_failure = resolved[:failure]
      return bin_failure if bin_failure
      bin = resolved[:path]

      # Ansible module: `rabbitmq-plugins list -E -m` - ALL enabled plugins
      # (explicit + implicit), minimal output (bare names, one per line),
      # membership checked as an exact line match.
      listing = run_check_rc([bin, "list", "-E", "-m"])
      listing_failure = listing[:failure]
      return listing_failure if listing_failure
      enabled_lines = enabled_plugin_lines(listing[:stdout])

      enabled = [] of String
      disabled = [] of String
      apply_failure = desired_state == "enabled" ? apply_enabled(bin, plugins, enabled_lines, enabled, disabled) : apply_disabled(bin, plugins, enabled_lines, disabled)
      return apply_failure if apply_failure

      # changed only reflects what would actually change - the module's result
      # dict is {changed, enabled, disabled} with no msg at all
      # (exit_json(**result)), so the lists are what a registered result or -v
      # run must show.
      PluginResult.new(changed: !enabled.empty? || !disabled.empty?, failed: false,
        enabled: enabled, disabled: disabled)
    end

    private def desired_state : String
      @params["state"]? || "enabled"
    end

    private def broker_state : String
      @params["broker_state"]? || "online"
    end

    # AnsibleModule's choices validation, which runs before the module body.
    private def param_failure : PluginResult?
      unless desired_state.in?("enabled", "disabled")
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: enabled, disabled, got: #{desired_state}")
      end
      unless broker_state.in?("online", "offline")
        return PluginResult.new(changed: false, failed: true,
          msg: "value of broker_state must be one of: online, offline, got: #{broker_state}")
      end
      nil
    end

    private def apply_enabled(bin : String, plugins : Array(String), enabled_lines : Array(String), enabled : Array(String), disabled : Array(String)) : PluginResult?
      unless new_only?
        # state=enabled, new_only=false disables every enabled plugin not in
        # the requested names. Header lines ("Listing plugins with pattern
        # ...") contain spaces and are skipped the same way the Ansible module
        # skips them.
        enabled_lines.each do |line|
          next if line.includes?(" ") || plugins.includes?(line)
          failure = apply(bin, "disable", broker_state, line, disabled)
          return failure if failure
        end
      end
      plugins.each do |plugin|
        next if enabled_lines.includes?(plugin)
        failure = apply(bin, "enable", broker_state, plugin, enabled)
        return failure if failure
      end
      nil
    end

    private def apply_disabled(bin : String, plugins : Array(String), enabled_lines : Array(String), disabled : Array(String)) : PluginResult?
      enabled_lines.each do |line|
        next unless plugins.includes?(line)
        failure = apply(bin, "disable", broker_state, line, disabled)
        return failure if failure
      end
      nil
    end

    # `rabbitmq-plugins <enable|disable> --<broker_state> <plugin>` - the
    # module always passes the broker_state flag, so a failed call's cmd names
    # it too. A plugin is recorded only once its call succeeded, and check mode
    # records it without running the call: the module's _exec only lists
    # (force_exec_in_check_mode) and skips every enable/disable.
    private def apply(bin : String, action : String, broker_state : String, plugin : String, applied : Array(String)) : PluginResult?
      unless check_mode?
        result = run_check_rc([bin, action, "--#{broker_state}", plugin])
        failure = result[:failure]
        return failure if failure
      end
      applied << plugin
      nil
    end

    # run_command(..., check_rc=True): a non-zero rc fails the task with
    # stderr's rstripped text as msg and the command's own output attached.
    # cmd renders the argv the way basic.py's _clean_args does - shlex.quote
    # per token, spaces between; Shell.quote_arg leaves an already-safe token
    # bare exactly like shlex.quote does.
    private def run_check_rc(argv : Array(String)) : NamedTuple(stdout: String, stderr: String, failure: PluginResult?)
      result = remote_exec(argv.map { |arg| shell_single_quote(arg) }.join(' '))
      return {stdout: result[:stdout], stderr: result[:stderr], failure: nil} if result[:exit_code] == 0

      failure = PluginResult.new(changed: false, failed: true, msg: result[:stderr].rstrip,
        cmd: argv.map { |arg| Shell.quote_arg(arg) }.join(' '), rc: result[:exit_code],
        stdout: result[:stdout], stderr: result[:stderr],
        stdout_lines: result[:stdout].lines.map(&.chomp),
        stderr_lines: result[:stderr].lines.map(&.chomp))
      {stdout: result[:stdout], stderr: result[:stderr], failure: failure}
    end

    private def new_only? : Bool
      as_bool(@params["new_only"]?)
    end

    # rabbitmq_plugin.py declares supports_check_mode=True and routes every
    # rabbitmq-plugins invocation through _exec(), which skips the command in
    # check mode (only the `list -E -m` probe is force-executed). The requested
    # names still land in enabled/disabled, so check mode predicts `changed`
    # for a plugin the broker does not even ship; running the enable for real
    # instead failed the whole task (#1751).
    private def check_mode? : Bool
      true?(@params["_ansible_check_mode"]?)
    end

    private def as_bool(value) : Bool
      case value
      when Bool   then value
      when String then value == "true" || value == "True" || value == "yes"
      else             false
      end
    end

    # Ansible's RabbitMqPlugins.__init__ resolves the binary once, before any
    # listing: a `prefix:` names a RabbitMQ install root whose bin/ (else
    # sbin/) directory holds rabbitmq-plugins, and without one the executable
    # comes from get_bin_path(required=True). Both misses are fail_json with a
    # bare msg, no command having run yet.
    private def plugin_bin : NamedTuple(path: String, failure: PluginResult?)
      if prefix = @params["prefix"]?.presence
        dir = [File.join(prefix, "bin"), File.join(prefix, "sbin")].find { |candidate| remote_dir_exists?(candidate) }
        unless dir
          return {path: "", failure: PluginResult.new(changed: false, failed: true,
            msg: "No binary folder in prefix #{prefix}")}
        end
        return {path: File.join(dir, "rabbitmq-plugins"), failure: nil}
      end

      if found = find_required_binary("rabbitmq-plugins")
        return {path: found, failure: nil}
      end
      {path: "", failure: PluginResult.new(changed: false, failed: true,
        msg: PluginHelpers::GetBinPath.missing_executable_error("rabbitmq-plugins", @bin_searched_paths))}
    end

    private def enabled_plugin_lines(stdout : String) : Array(String)
      # real get_all(): collect output lines until the first empty line.
      # With -m the plugin rows are bare names; banner lines (ANSI on some
      # versions) contain spaces and never equal a requested name.
      stdout.gsub(/\e\[[0-9;]*m/, "").each_line
        .take_while { |line| !line.strip.empty? }
        .map(&.strip)
        .reject(&.empty?)
        .to_a
    end
  end
end

if ARGV.size == 1 && ARGV[0] == "--self-test"
  # no-op hook for compile checks
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::RabbitmqPluginPlugin.new(config)
plugin.run
