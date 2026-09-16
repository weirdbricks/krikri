#!/usr/bin/env crystal

require "json"
require "xml"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/firewalld_command"

module Krikri
  # Firewalld plugin - manages firewalld zone configuration. Compatible
  # with Ansible's ansible.posix.firewalld module.
  #
  # Supported parameters:
  # - zone: firewalld zone - defaults to the configured default zone
  #   (firewalld.conf's DefaultZone, resolved over D-Bus when a daemon
  #   is running) when omitted, matching real Ansible's own documented
  #   behavior ("the default zone can be configured per system but
  #   public is default from upstream") rather than requiring it.
  # - state: enabled | disabled for every "thing" below except target: -
  #   present/absent are ONLY valid for target: (a zone-level operation);
  #   using them with any other thing fails with real Ansible's own
  #   "absent and present state can only be used in zone level
  #   operations" message (verified live against a real ansible-playbook
  #   run - this plugin previously accepted present/absent everywhere as
  #   silent synonyms, more lenient than real Ansible rather than
  #   matching it). Those four are also the ONLY valid values - real
  #   Ansible's argument spec rejects anything else up front (found by
  #   the podman-diff firewalld round: this plugin previously accepted
  #   any unrecognized state as a silent "disabled").
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
  # The permanent/offline backend is NOT `firewall-offline-cmd` - real
  # ansible.posix.firewalld's offline mode never shells out to it; it
  # uses firewalld's own Python Firewall(offline=True), which loads the
  # /usr/lib/firewalld + /etc/firewalld zone XML and writes changes back
  # to /etc/firewalld/zones/<zone>.xml. firewall-offline-cmd dies
  # entirely in environments where its protocol validation can't resolve
  # entries like 'esp' (getprotobyname('esp') fails in a slim container
  # - this plugin previously failed every permanent operation there
  # while real Ansible succeeded), so the offline backend here is the
  # same direct XML manipulation the real module's Python does (see
  # FirewalldCommand's ZoneXml helpers). The one exception is
  # rich_rule, whose string form needs firewalld's own Rich_Rule
  # parser for XML serialization AND query canonicalization - it stays
  # on the firewall-offline-cmd path, which works on hosts where that
  # binary works and fails (rather than silently mis-editing) where it
  # doesn't. A real `immediate:` runtime change against a *live*
  # firewalld goes through `firewall-cmd`/D-Bus and needs the daemon
  # actually running - validate_permanent_immediate fails that
  # combination (immediate requested, daemon absent) with real
  # Ansible's own message.
  #
  # `firewall-offline-cmd`'s command shape and quirks (verified
  # empirically against a real firewalld 2.1.1 install, since much of
  # this isn't documented by `ansible-doc` at all - it belongs to the
  # underlying CLI tool, not the Ansible module) live in
  # `src/krikri/plugin_helpers/firewalld_command.cr`, alongside the
  # ZoneXml backend.
  #
  # - port_forward: a list of at most one dict
  #   ({port, proto, toport, toaddr?}), structurally different from
  #   every other "thing" above's simple scalar value - real Ansible's
  #   own module (`ForwardPortTransaction`) fails with "Only one port
  #   forward supported at a time" for more than one entry, and builds
  #   a compound `port=X:proto=Y:toport=Z[:toaddr=W]` value (`toaddr`
  #   omitted when absent) for the runtime path; the offline path
  #   stores the same fields as a <forward-port> element.
  #
  # Not implemented: `timeout`, `immediate` (meaningless without a
  # running daemon - offline always forces it false, matching real
  # Ansible's own behavior).
  class FirewalldPlugin < BasePlugin
    ETC_ZONE_DIR = "/etc/firewalld/zones"
    USR_ZONE_DIR = "/usr/lib/firewalld/zones"
    ETC_CONF_DIR = "/etc/firewalld"
    USR_CONF_DIR = "/usr/lib/firewalld"

    # Which change contexts the current request touches, set by
    # #validate_permanent_immediate (see its own comment).
    @do_runtime = false
    @do_permanent = true

    def execute : PluginResult
      state = @params["state"]?
      unless state
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: state")
      end

      # Real Ansible's argument spec: state choices are enabled,
      # disabled, present, absent - anything else fails at argument
      # validation time, before any firewalld interaction (verified
      # live: "value of state must be one of: absent, disabled, enabled,
      # present, got: enabled-forever"). This plugin previously
      # accepted any other value as a silent "disabled".
      unless %w[enabled disabled present absent].includes?(state)
        return PluginResult.new(changed: false, failed: true, msg: "value of state must be one of: absent, disabled, enabled, present, got: #{state}")
      end

      zone = resolve_zone
      unless zone
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: zone (and no default zone could be determined)")
      end

      if validation_error = validate_permanent_immediate(zone)
        return validation_error
      end

      # Real Ansible's own mutually_exclusive constraint spans target
      # and port_forward too - target+port together is a validation
      # failure there, not a silently-honored target. (Live-verified
      # error message shape: "parameters are mutually exclusive:
      # icmp_block|...|source|target".)
      all_things = PluginHelpers::FirewalldCommand::SUPPORTED_THINGS + ["port_forward", "target"]
      if all_things.count { |key| @params[key]? } > 1
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: icmp_block|icmp_block_inversion|service|protocol|port|port_forward|rich_rule|interface|forward|masquerade|source|target")
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

      if thing = PluginHelpers::FirewalldCommand.thing(@params)
        key, value = thing
        return run(zone, state, key, value)
      end

      # Zero "things" is NOT an error: verified live, real Ansible with
      # only zone+state (enabled, permanent) succeeds as a no-op
      # (changed=false) - its transaction list is simply empty. This
      # plugin previously failed such a task with an "exactly one of
      # ... is required" error.
      PluginResult.new(changed: false, failed: false, msg: "", zone: zone)
    end

    private def run_target(zone : String, state : String, target : String) : PluginResult
      # Real Ansible's own ZoneTargetTransaction FAILS any target change
      # in the immediate (runtime) context - a zone's target is only
      # settable permanently ("Zone operations must be permanent. Make
      # sure you didn't set the 'permanent' flag to 'false' or the
      # 'immediate' flag to 'true.'" - the real module's own
      # tx_not_permanent_error_msg, raised by BOTH
      # set_enabled_immediate and set_disabled_immediate). So even a
      # bare `target:` task (immediate silently forced true) fails under
      # real Ansible, and one with permanent+immediate fails too - the
      # immediate transaction runs first. Only permanent-only requests
      # proceed.
      if @do_runtime
        return PluginResult.new(changed: false, failed: true, msg: "Zone operations must be permanent. Make sure you didn't set the 'permanent' flag to 'false' or the 'immediate' flag to 'true'.", zone: zone)
      end

      want_present = state == "enabled" || state == "present"
      desired = want_present ? target : "default"

      content = read_zone_xml(zone)
      return PluginResult.new(changed: false, failed: true, msg: "INVALID_ZONE: #{zone}", zone: zone) unless content

      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if zone_target(content) == desired

      if true?(@params["_ansible_check_mode"]?)
        return PluginResult.new(changed: true, failed: false, msg: "", zone: zone)
      end

      write_zone_xml(zone, PluginHelpers::FirewalldCommand.zone_set_target(content, desired))
      PluginResult.new(changed: true, failed: false, msg: "", zone: zone)
    end

    # The zone root's target attribute - a zone's target isn't optional
    # the way an entry is, its ABSENCE is the "default" target (see the
    # class comment on state: disabled/absent resetting to "default").
    private def zone_target(content : String) : String
      root = XML.parse(content).root
      return "default" unless root && root.name == "zone"
      root["target"]? || "default"
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

      want_present = state == "enabled"
      check_mode = true?(@params["_ansible_check_mode"]?)
      changed = false

      if @do_runtime
        result = forward_port_runtime(zone, value, want_present, check_mode)
        return result if result.failed?
        changed ||= result.changed?
      end

      if @do_permanent
        result = forward_port_offline(zone, entries[0], want_present, check_mode)
        return result if result.failed?
        changed ||= result.changed?
      end

      PluginResult.new(changed: changed, failed: false, msg: "", zone: zone)
    end

    private def forward_port_runtime(zone : String, value : String, want_present : Bool, check_mode : Bool) : PluginResult
      present = remote_exec(PluginHelpers::FirewalldCommand.forward_port_query_command(zone, value, "firewall-cmd"))[:exit_code] == 0
      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if present == want_present
      return PluginResult.new(changed: true, failed: false, msg: "", zone: zone) if check_mode

      cmd = want_present ? PluginHelpers::FirewalldCommand.forward_port_add_command(zone, value, "firewall-cmd") : PluginHelpers::FirewalldCommand.forward_port_remove_command(zone, value, "firewall-cmd")
      result = remote_exec(cmd)
      return PluginResult.new(changed: false, failed: true, msg: result[:stdout], zone: zone) if result[:exit_code] != 0

      PluginResult.new(changed: true, failed: false, msg: "", zone: zone)
    end

    private def forward_port_offline(zone : String, entry : JSON::Any, want_present : Bool, check_mode : Bool) : PluginResult
      content = read_zone_xml(zone)
      return PluginResult.new(changed: false, failed: true, msg: "INVALID_ZONE: #{zone}", zone: zone) unless content

      element, attrs = PluginHelpers::FirewalldCommand.forward_port_element(entry)
      present = PluginHelpers::FirewalldCommand.zone_query(content, element, attrs)
      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if present == want_present
      return PluginResult.new(changed: true, failed: false, msg: "", zone: zone) if check_mode

      new_content = want_present ? PluginHelpers::FirewalldCommand.zone_add(content, element, attrs) : PluginHelpers::FirewalldCommand.zone_remove(content, element, attrs)
      if new_content
        write_zone_xml(zone, new_content)
        return PluginResult.new(changed: true, failed: false, msg: "", zone: zone)
      end

      PluginResult.new(changed: false, failed: false, msg: "", zone: zone)
    end

    private def run(zone : String, state : String, key : String, value : String) : PluginResult
      want_present = state == "enabled"
      check_mode = true?(@params["_ansible_check_mode"]?)
      changed = false

      if @do_runtime
        present = remote_exec(PluginHelpers::FirewalldCommand.query_command(zone, key, value, "firewall-cmd"))[:exit_code] == 0
        if present != want_present
          return PluginResult.new(changed: true, failed: false, msg: "", zone: zone) if check_mode
          cmd = want_present ? PluginHelpers::FirewalldCommand.add_command(zone, key, value, "firewall-cmd") : PluginHelpers::FirewalldCommand.remove_command(zone, key, value, "firewall-cmd")
          result = remote_exec(cmd)
          return PluginResult.new(changed: false, failed: true, msg: result[:stdout], zone: zone) if result[:exit_code] != 0
          changed = true
        end
      end

      if @do_permanent
        if key == "rich_rule"
          result = run_rich_rule_offline(zone, want_present, value, check_mode)
          return result if result.failed?
          changed ||= result.changed?
        else
          result = run_thing_offline(zone, key, value, want_present, check_mode)
          return result if result.failed?
          changed ||= result.changed?
        end
      end

      PluginResult.new(changed: changed, failed: false, msg: "", zone: zone)
    end

    # The XML-file backend for every "thing" except rich_rule (see the
    # class comment) - real Ansible's own offline mode edits the zone
    # config files via firewalld's Python Firewall(offline=True); the
    # direct file manipulation below mirrors that. The zone file is
    # read from /etc (user config) first, then /usr/lib (stock), exactly
    # the real module's load order; a zone present in neither is real
    # Ansible's INVALID_ZONE failure.
    private def run_thing_offline(zone : String, key : String, value : String, want_present : Bool, check_mode : Bool) : PluginResult
      content = read_zone_xml(zone)
      return PluginResult.new(changed: false, failed: true, msg: "INVALID_ZONE: #{zone}", zone: zone) unless content

      element, attrs = PluginHelpers::FirewalldCommand.zone_element(key, value)
      present = PluginHelpers::FirewalldCommand.zone_query(content, element, attrs)
      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if present == want_present
      return PluginResult.new(changed: true, failed: false, msg: "", zone: zone) if check_mode

      new_content = want_present ? PluginHelpers::FirewalldCommand.zone_add(content, element, attrs) : PluginHelpers::FirewalldCommand.zone_remove(content, element, attrs)
      if new_content
        write_zone_xml(zone, new_content)
        return PluginResult.new(changed: true, failed: false, msg: "", zone: zone)
      end

      PluginResult.new(changed: false, failed: false, msg: "", zone: zone)
    end

    # rich_rule stays on the firewall-offline-cmd path (see the class
    # comment - its string form needs firewalld's own Rich_Rule parser,
    # both for XML serialization and for query canonicalization), so
    # this only works on hosts where that binary works.
    private def run_rich_rule_offline(zone : String, want_present : Bool, value : String, check_mode : Bool) : PluginResult
      present = remote_exec(PluginHelpers::FirewalldCommand.query_command(zone, "rich_rule", value))[:exit_code] == 0
      return PluginResult.new(changed: false, failed: false, msg: "", zone: zone) if present == want_present
      return PluginResult.new(changed: true, failed: false, msg: "", zone: zone) if check_mode

      cmd = want_present ? PluginHelpers::FirewalldCommand.add_command(zone, "rich_rule", value) : PluginHelpers::FirewalldCommand.remove_command(zone, "rich_rule", value)
      result = remote_exec(cmd)
      return PluginResult.new(changed: false, failed: true, msg: result[:stdout], zone: zone) if result[:exit_code] != 0

      PluginResult.new(changed: true, failed: false, msg: "", zone: zone)
    end

    # Writes back to /etc/firewalld/zones/<zone>.xml - real Ansible's
    # offline mode persists every change there (firewalld's own
    # set_zone_config), including changes to a stock /usr/lib zone,
    # which effectively copies it into user config.
    private def write_zone_xml(zone : String, content : String) : Nil
      Dir.mkdir_p(ETC_ZONE_DIR)
      File.write(File.join(ETC_ZONE_DIR, "#{zone}.xml"), content)
    end

    private def read_zone_xml(zone : String) : String?
      return nil if zone.includes?("/") || zone.includes?("..")
      [File.join(ETC_ZONE_DIR, "#{zone}.xml"), File.join(USR_ZONE_DIR, "#{zone}.xml")].each do |path|
        return File.read(path) if File.exists?(path)
      end
      nil
    end

    # `zone:` (real Ansible's own doc: "the default zone can be
    # configured per system but public is default from upstream") -
    # resolves the LIVE daemon's default zone when one is running (real
    # Ansible resolves the default over its D-Bus connection), the
    # on-disk configured one (firewalld.conf's DefaultZone, the same
    # thing firewall's offline Python reads) otherwise.
    private def resolve_zone : String?
      given = @params["zone"]?
      return given if given

      if firewalld_running?
        zone = remote_exec("firewall-cmd --get-default-zone")[:stdout].strip
        return zone unless zone.empty?
        return nil
      end

      offline_default_zone
    rescue
      nil
    end

    private def offline_default_zone : String?
      found_conf = false
      [File.join(ETC_CONF_DIR, "firewalld.conf"), File.join(USR_CONF_DIR, "firewalld.conf")].each do |path|
        next unless File.exists?(path)
        found_conf = true
        File.read(path).each_line do |line|
          line = line.strip
          next if line.empty? || line.starts_with?("#")
          key, value = line.split("=", 2)
          return value.strip if key.strip.downcase == "defaultzone"
        end
      end
      found_conf ? "public" : nil
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

      # Which contexts this request touches: an immediate action against
      # a live daemon goes through `firewall-cmd` (the D-Bus client CLI,
      # the same channel real Ansible's own firewall module drives), a
      # permanent one through `firewall-offline-cmd` (on-disk zone XML).
      # The daemon-running + immediate combination used to be a hard
      # "not implemented" failure - it is the backend now.
      @do_runtime = immediate && !fw_offline
      @do_permanent = permanent || !@do_runtime

      nil
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::FirewalldPlugin.new(config)
plugin.run
