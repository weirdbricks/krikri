#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/ufw_command"

module CrystalPlay
  # Ufw plugin - manages the Uncomplicated Firewall. Compatible with
  # Ansible's ufw module - registered here as community.general.ufw,
  # matching its real FQCN (verified via `ansible-doc ufw`; it lives in
  # the separate community.general collection, not ansible-core).
  #
  # Supported parameters:
  # - state: enabled | disabled | reloaded | reset
  # - logging: on/off/low/medium/high/full
  # - default: allow | deny | reject (with optional `direction:`)
  # - rule: allow | deny | reject | limit, plus direction/interface/
  #   interface_in/interface_out/log/from_ip/from_port/to_ip/to_port/
  #   proto/name (app profile)/comment/delete/insert/route - command
  #   shape verified against community.general's actual ufw.py source
  #   (see `src/crystal_play/plugin_helpers/ufw_command.cr`)
  # - check_mode: run with `--dry-run` instead of applying for real
  #
  # `ufw` itself refuses to run at all without root - even a bare
  # `ufw status` fails with "ERROR: You need to be root to run this
  # script" - so, unlike every other plugin added in this phase, this one
  # could not be verified end-to-end against real ansible-playbook via
  # the compat harness: the harness's container lacks working netfilter
  # access even running as root (confirmed: `ufw status` fails inside it
  # with an iptables permission error unrelated to ufw itself). The
  # command-construction logic is verified against real Ansible's actual
  # source, and the "Skipping" idempotency signal is the literal
  # substring real ufw's own module checks for - but the actual firewall
  # behavior has not been confirmed against a real, working ufw
  # installation the way every other plugin in this codebase has been.
  #
  # Not implemented: `insert_relative_to` values other than the default
  # `zero` (first-ipv4/last-ipv4/first-ipv6/last-ipv6 need to parse
  # `ufw status numbered` first, which needs working netfilter access to
  # verify at all).
  class UfwPlugin < BasePlugin
    def execute : PluginResult
      if state = @params["state"]?
        return run_state(state)
      end

      if logging = @params["logging"]?
        return run_simple(PluginHelpers::UfwCommand.logging_command(logging))
      end

      if default_value = @params["default"]?
        cmd = PluginHelpers::UfwCommand.default_command(default_value, @params["direction"]?)
        return run_simple(cmd)
      end

      if @params["rule"]?
        return run_rule
      end

      PluginResult.new(changed: false, failed: true, msg: "one of state, logging, default, or rule is required")
    end

    private def run_state(state : String) : PluginResult
      cmd = PluginHelpers::UfwCommand.state_command(state)
      unless cmd
        return PluginResult.new(changed: false, failed: true, msg: "state must be one of enabled, disabled, reloaded, reset")
      end

      if is_true?(@params["check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "Would run: #{cmd} (check mode)")
      end

      result = remote_exec(cmd)
      PluginResult.new(changed: result[:exit_code] == 0, failed: result[:exit_code] != 0, msg: result[:stdout])
    end

    private def run_simple(cmd : String) : PluginResult
      if is_true?(@params["check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "Would run: #{cmd} (check mode)")
      end

      result = remote_exec(cmd)
      PluginResult.new(changed: result[:exit_code] == 0, failed: result[:exit_code] != 0, msg: result[:stdout])
    end

    private def run_rule : PluginResult
      check_mode = is_true?(@params["check_mode"]?)
      cmd = PluginHelpers::UfwCommand.rule_command(@params, dry_run: check_mode)

      result = remote_exec(cmd)
      changed = PluginHelpers::UfwCommand.changed_from_output?(result[:stdout])
      PluginResult.new(changed: changed, failed: result[:exit_code] != 0, msg: result[:stdout])
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::UfwPlugin.new(config)
plugin.run
