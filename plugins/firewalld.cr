#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/firewalld_command"

module CrystalPlay
  # Firewalld plugin - manages firewalld zone configuration. Compatible
  # with Ansible's ansible.posix.firewalld module.
  #
  # Supported parameters:
  # - zone: firewalld zone - defaults to `firewall-offline-cmd --get-
  #   default-zone` when omitted, matching real Ansible's own documented
  #   behavior ("the default zone can be configured per system but
  #   public is default from upstream") rather than requiring it.
  # - state: enabled | disabled for every "thing" below except target: -
  #   present/absent are ONLY valid for target: (a zone-level operation);
  #   using them with any other thing fails with real Ansible's own
  #   "absent and present state can only be used in zone level
  #   operations" message (verified live against a real ansible-playbook
  #   run - this plugin previously accepted present/absent everywhere as
  #   silent synonyms, more lenient than real Ansible rather than
  #   matching it)
  # - permanent/immediate/offline: ported real Ansible's own validation
  #   logic exactly (see #validate_permanent_immediate) rather than
  #   requiring `offline: true, permanent: true` explicitly - real
  #   Ansible defaults all three false, silently forces `immediate` true
  #   when neither permanent nor immediate is given, and only fails
  #   outright when an `immediate` (live-daemon) action is actually
  #   requested/defaulted against a firewalld that isn't reachable (auto-
  #   detected via `firewall-cmd --state`, the CLI equivalent of real
  #   Ansible's own D-Bus-connection-attempt probe).
  # - one of: service, port, rich_rule, source, masquerade, interface,
  #   icmp_block, protocol, icmp_block_inversion, forward, target -
  #   matching real Ansible's own mutually_exclusive constraint (exactly
  #   one "thing" per task). Every flag shape below was verified live
  #   against a real `firewall-offline-cmd` (firewalld 2.3.1, installed
  #   fresh in a throwaway Debian container specifically to check these -
  #   `firewall-offline-cmd` edits the on-disk zone XML directly, no
  #   running daemon/kernel netfilter access needed, so a plain
  #   unprivileged container is enough).
  # - target: NOT an add/remove/query "thing" the way the others are -
  #   verified against real ansible.posix.firewalld's own
  #   `ZoneTargetTransaction` source and live-verified against
  #   `firewall-offline-cmd`: uses `--set-target=<value>`/`--get-target`
  #   instead. `state: enabled`/`present` sets the zone's target to the
  #   given value; `state: disabled`/`absent` resets it to the literal
  #   string `"default"` (real Ansible's own documented behavior:
  #   "Reset zone %s target to default" - NOT simply "remove", since a
  #   zone's target isn't optional the way a service/port/etc entry is).
  #
  # This only implements permanent/offline-style changes - i.e.
  # `firewall-offline-cmd`, which edits firewalld's on-disk zone XML
  # directly without needing a running firewalld daemon at all. A real
  # `immediate:` runtime change against a *live* firewalld (going
  # through `firewall-cmd`/D-Bus) needs an actual running firewalld
  # service - the same category of gap already documented for
  # `service:` in this codebase (no init system in the compat harness
  # container) - so it's not implemented here; that specific combination
  # (firewalld genuinely running AND an immediate action actually
  # requested/defaulted) fails with a clear message rather than silently
  # doing the wrong thing. Every other combination - which is every
  # combination this plugin is ever likely to see in the containerized/
  # no-init-system hosts this project's benchmark rounds target - is
  # serviced via `firewall-offline-cmd` regardless of the `offline:`
  # param's own value, matching real Ansible's own auto-detected
  # fallback.
  #
  # `firewall-offline-cmd`'s command shape and quirks (verified
  # empirically against a real firewalld 2.1.1 install, since much of
  # this isn't documented by `ansible-doc` at all - it belongs to the
  # underlying CLI tool, not the Ansible module) live in
  # `src/crystal_play/plugin_helpers/firewalld_command.cr`.
  #
  # - port_forward: a list of at most one dict
  #   ({port, proto, toport, toaddr?}), structurally different from
  #   every other "thing" above's simple scalar value - real Ansible's
  #   own module (`ForwardPortTransaction`) fails with "Only one port
  #   forward supported at a time" for more than one entry, and builds
  #   a compound `port=X:proto=Y:toport=Z[:toaddr=W]` value (`toaddr`
  #   omitted when absent). Verified live against a real
  #   `firewall-offline-cmd` (firewalld 1.3.3, Debian bookworm
  #   container): `--add-forward-port=`/`--remove-forward-port=`/
  #   `--query-forward-port=` all take this same compound value and
  #   exist as their own distinct flags (NOT reachable via the generic
  #   add/remove/query-<thing> pattern the other things use).
  #
  # Not implemented: `timeout`, `immediate` (meaningless without a
  # running daemon - offline always forces it false, matching real
  # Ansible's own behavior).
  class FirewalldPlugin < BasePlugin
    def execute : PluginResult
      state = @params["state"]?
      unless state
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: state")
      end

      zone = resolve_zone
      unless zone
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: zone (and no default zone could be determined)")
      end

      if validation_error = validate_permanent_immediate(zone)
        return validation_error
      end

      if target = @params["target"]?
        return run_target(zone, state, target)
      end

      # Real Ansible's own validation ("absent and present state can
      # only be used in zone level operations" - verified live against
      # a real `ansible-playbook`/`ansible.posix.firewalld` run):
      # `present`/`absent` are only valid for `target:` operations
      # (handled above, already returned). Every other "thing" -
      # service/port/rich_rule/port_forward/etc - requires
      # `enabled`/`disabled` instead. Found live testing `port_forward:`
      # against real Ansible in a round-34 host round: this plugin
      # previously accepted `present`/`absent` as silent synonyms for
      # every thing, more lenient than real Ansible rather than matching
      # it.
      if state == "present" || state == "absent"
        return PluginResult.new(changed: false, failed: true, msg: "absent and present state can only be used in zone level operations")
      end

      if port_forward = @params["port_forward"]?
        return run_port_forward(zone, state, port_forward)
      end

      thing = PluginHelpers::FirewalldCommand.thing(@params)
      unless thing
        return PluginResult.new(changed: false, failed: true, msg: "exactly one of service, port, rich_rule, source, masquerade, interface, icmp_block, protocol, icmp_block_inversion, forward, port_forward, target is required")
      end

      key, value = thing
      run(zone, state, key, value)
    end

    private def run_target(zone : String, state : String, target : String) : PluginResult
      want_present = state == "enabled" || state == "present"
      desired = want_present ? target : "default"

      current = remote_exec("firewall-offline-cmd --zone=#{zone} --get-target")[:stdout].strip
      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if current == desired

      if true?(@params["check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "", zone: zone)
      end

      result = remote_exec("firewall-offline-cmd --zone=#{zone} --set-target=#{desired}")
      PluginResult.new(changed: result[:exit_code] == 0, failed: result[:exit_code] != 0, msg: result[:stdout], zone: zone)
    end

    # Matches real Ansible's own `ForwardPortTransaction` construction
    # exactly: fails on >1 entries, requires port/proto/toport (checked
    # in that order, matching the real module's own error-message
    # order), `toaddr` optional and simply omitted from the compound
    # value when absent.
    private def run_port_forward(zone : String, state : String, raw : String) : PluginResult
      entries = JSON.parse(raw).as_a
      return PluginResult.new(changed: false, failed: true, msg: "Only one port forward supported at a time") if entries.size > 1
      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if entries.empty?

      built = PluginHelpers::FirewalldCommand.port_forward_value(entries[0])
      return PluginResult.new(changed: false, failed: true, msg: built[:error] || "invalid port_forward value") unless value = built[:value]

      present = remote_exec(PluginHelpers::FirewalldCommand.forward_port_query_command(zone, value))[:exit_code] == 0
      want_present = state == "enabled"

      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if present == want_present

      if true?(@params["check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "", zone: zone)
      end

      cmd = want_present ? PluginHelpers::FirewalldCommand.forward_port_add_command(zone, value) : PluginHelpers::FirewalldCommand.forward_port_remove_command(zone, value)
      result = remote_exec(cmd)
      PluginResult.new(changed: result[:exit_code] == 0, failed: result[:exit_code] != 0, msg: result[:stdout], zone: zone)
    end

    private def run(zone : String, state : String, key : String, value : String) : PluginResult
      present = query(zone, key, value)
      want_present = state == "enabled"

      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if present == want_present

      if true?(@params["check_mode"]?)
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

    # `zone:` (real Ansible's own doc: "the default zone can be
    # configured per system but public is default from upstream") -
    # falls back to `firewall-offline-cmd --get-default-zone`, which
    # (like every other operation this plugin shells out to) works
    # without a live firewalld daemon. Returns nil only if firewalld
    # itself isn't installed at all (empty/failed output).
    private def resolve_zone : String?
      given = @params["zone"]?
      return given if given

      zone = remote_exec("firewall-offline-cmd --get-default-zone")[:stdout].strip
      zone.empty? ? nil : zone
    rescue
      nil
    end

    # Real firewalld's own Python module_utils auto-detects "offline"
    # by trying a live D-Bus connection first (`FirewallClient#
    # getDefaultZone`) and only operating in permanent-only/offline mode
    # if that fails - `firewall-cmd --state` is the CLI equivalent probe
    # (exit 0 + "running" only when a live daemon answers).
    private def firewalld_running? : Bool
      result = remote_exec("firewall-cmd --state")
      result[:exit_code] == 0 && result[:stdout].strip == "running"
    rescue
      false
    end

    # Ports real Ansible's own `permanent`/`immediate`/`offline` twisty
    # validation logic (ansible/posix/plugins/modules/firewalld.py's
    # `main()`) instead of the previous blanket "offline: true,
    # permanent: true both required" gate - that combination isn't even
    # a real Ansible requirement (permanent defaults false, immediate
    # defaults false, offline defaults false; when neither permanent nor
    # immediate is given, immediate is silently forced true). Returns a
    # failed PluginResult exactly matching real Ansible's own error
    # messages for the two validation failures it can raise, nil if the
    # request is valid and this plugin can service it (permanent-only,
    # offline-style - covers every case this plugin's own
    # `firewall-offline-cmd`-based implementation actually supports).
    private def validate_permanent_immediate(zone : String) : PluginResult?
      permanent = true?(@params["permanent"]?)
      immediate = true?(@params["immediate"]?)
      offline_param = true?(@params["offline"]?)
      fw_offline = !firewalld_running?

      if offline_param
        unless permanent
          return PluginResult.new(changed: false, failed: true, msg: "offline cannot be enabled unless permanent changes are allowed", zone: zone)
        end
        immediate = false if fw_offline
      end

      immediate = true if !permanent && !immediate

      if immediate && fw_offline
        return PluginResult.new(changed: false, failed: true, msg: "firewall is not currently running, unable to perform immediate actions without a running firewall daemon", zone: zone)
      end

      # A genuinely live firewalld daemon plus a real `immediate:` runtime
      # change - the one combination real Ansible services over a live
      # D-Bus connection that this plugin has no implementation for at
      # all (see this file's own header comment). Narrower than the
      # previous blanket requirement: only reached when firewalld is
      # actually running AND immediate was actually requested/defaulted.
      if immediate && !fw_offline
        return PluginResult.new(changed: false, failed: true, msg: "immediate changes against a live firewalld daemon are not implemented (only permanent/offline-style changes are supported)", zone: zone)
      end

      nil
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::FirewalldPlugin.new(config)
plugin.run
