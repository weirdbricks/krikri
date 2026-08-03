#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/firewalld_command"

module CrystalPlay
  # Firewalld plugin - manages firewalld zone configuration. Compatible
  # with Ansible's ansible.posix.firewalld module.
  #
  # Supported parameters:
  # - zone: firewalld zone (required)
  # - state: enabled | present (add) | disabled | absent (remove)
  # - permanent: must be true (see below) - matches real Ansible's own
  #   validation ("offline cannot be enabled unless permanent changes are
  #   allowed")
  # - offline: must be true (see below)
  # - one of: service, port, rich_rule, source, masquerade - matching
  #   real Ansible's own mutually_exclusive constraint (exactly one
  #   "thing" per task)
  #
  # This only implements `offline: true, permanent: true` - i.e.
  # `firewall-offline-cmd`, which edits firewalld's on-disk zone XML
  # directly without needing a running firewalld daemon at all. The
  # default, more common real-world usage (`offline: false`, going
  # through `firewall-cmd`/D-Bus against a *live* firewalld) needs an
  # actual running firewalld service - the same category of gap already
  # documented for `service:` in this codebase (no init system in the
  # compat harness container) - so it's not implemented here; a task
  # without `offline: true` fails with a clear message rather than
  # silently doing the wrong thing.
  #
  # `firewall-offline-cmd`'s command shape and quirks (verified
  # empirically against a real firewalld 2.1.1 install, since much of
  # this isn't documented by `ansible-doc` at all - it belongs to the
  # underlying CLI tool, not the Ansible module) live in
  # `src/crystal_play/plugin_helpers/firewalld_command.cr`.
  #
  # Not implemented: `interface`, `icmp_block`/`icmp_block_inversion`,
  # `target`, `forward`, `port_forward`, `protocol`, `timeout`,
  # `immediate` (meaningless without a running daemon - offline always
  # forces it false, matching real Ansible's own behavior).
  class FirewalldPlugin < BasePlugin
    def execute : PluginResult
      zone = @params["zone"]?
      state = @params["state"]?
      unless zone && state
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: zone and state are both required")
      end

      unless is_true?(@params["offline"]?) && is_true?(@params["permanent"]?)
        return PluginResult.new(changed: false, failed: true, msg: "only offline: true, permanent: true is implemented (no running firewalld daemon support)")
      end

      thing = PluginHelpers::FirewalldCommand.thing(@params)
      unless thing
        return PluginResult.new(changed: false, failed: true, msg: "exactly one of service, port, rich_rule, source, masquerade is required")
      end

      key, value = thing
      run(zone, state, key, value)
    end

    private def run(zone : String, state : String, key : String, value : String) : PluginResult
      present = query(zone, key, value)
      want_present = state == "enabled" || state == "present"

      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if present == want_present

      if is_true?(@params["check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "", zone: zone)
      end

      cmd = want_present ? PluginHelpers::FirewalldCommand.add_command(zone, key, value) : PluginHelpers::FirewalldCommand.remove_command(zone, key, value)
      result = remote_exec(cmd)

      PluginResult.new(changed: result[:exit_code] == 0, failed: result[:exit_code] != 0, msg: result[:stdout], zone: zone)
    end

    private def query(zone : String, key : String, value : String) : Bool
      cmd = PluginHelpers::FirewalldCommand.query_command(zone, key, value)
      remote_exec(cmd)[:exit_code] == 0
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::FirewalldPlugin.new(config)
plugin.run
