#!/usr/bin/env crystal

require "json"
require "krikri-xml"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/firewalld_command"

module Krikri
  # Firewalld plugin - manages firewalld zone configuration. Compatible
  # with Ansible's ansible.posix.firewalld module.
  #
  # Supported parameters:
  # - zone: firewalld zone - defaults to the configured default zone
  #   (firewalld.conf's DefaultZone, resolved over D-Bus when a daemon
  #   is running) when omitted, matching Ansible's own documented
  #   behavior ("the default zone can be configured per system but
  #   public is default from upstream") rather than requiring it.
  # - state: enabled | disabled for every "thing" below. present/absent
  #   are ONLY valid for zone-level operations - which in real
  #   ansible.posix.firewalld's own main() means exactly two things: a
  #   bare zone: with no "thing" param at all (ZoneTransaction - real
  #   Ansible accepts `zone: myzone state: present permanent: true`
  #   with nothing else as a zone create/delete; round900593
  #   Thulium-Drake.firewalld), or target: (ZoneTargetTransaction).
  #   Using them with any other thing fails with Ansible's own
  #   "absent and present state can only be used in zone level
  #   operations" message (verified live against a ansible-playbook
  #   run - this plugin previously accepted present/absent everywhere as
  #   silent synonyms, more lenient than Ansible rather than
  #   matching it). Those four are also the ONLY valid values - real
  #   Ansible's argument spec rejects anything else up front (found by
  #   the podman-diff firewalld round: this plugin previously accepted
  #   any unrecognized state as a silent "disabled").
  # - permanent/immediate/offline: ported Ansible's own validation
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
  #   matching Ansible's own mutually_exclusive constraint (exactly
  #   one "thing" per task). Every flag shape below was verified live
  #   against a real `firewall-offline-cmd` (firewalld 2.3.1, installed
  #   fresh in a throwaway Debian container specifically to check these -
  #   `firewall-offline-cmd` edits the on-disk zone XML directly, no
  #   running daemon/kernel netfilter access needed, so a plain
  #   unprivileged container is enough).
  # - target: NOT an add/remove/query "thing" the way the others are -
  #   verified against Ansible.posix.firewalld's own
  #   `ZoneTargetTransaction` source and live-verified against
  #   `firewall-offline-cmd`: uses `--set-target=<value>`/`--get-target`
  #   instead. `state: enabled`/`present` sets the zone's target to the
  #   given value; `state: disabled`/`absent` resets it to the literal
  #   string `"default"` (Ansible's own documented behavior:
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
  # while Ansible succeeded), so the offline backend here is the
  # same direct XML manipulation the Ansible module's Python does (see
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
  #   every other "thing" above's simple scalar value - Ansible's
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
    # firewalld's own service catalogue: the service XMLs it defines
    # (and the only names a zone may reference) - the same two dirs its
    # fw_service.py loads, /etc winning over /usr/lib.
    SERVICE_DIRS = ["/usr/lib/firewalld/services", "/etc/firewalld/services"]

    # Which change contexts the current request touches, set by
    # #validate_permanent_immediate (see its own comment).
    @do_runtime = false
    @do_permanent = true

    # Ansible's result msg is built from a msgs list each
    # transaction appends to (the Ansible module's self.msgs): a
    # context line first ("Permanent and Non-Permanent(immediate)
    # operation" / "Permanent operation" / "Non-permanent operation"),
    # then per-change detail lines, then - only on hosts where firewalld
    # is not running - the trailing "(offline operation: only on-disk
    # configs were altered)" note. Failure results wrap the same list:
    # "ERROR: Exception caught: <exception>[ <joined msgs>]".
    @msgs = [] of String
    @fw_offline = false

    def execute : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      state = @params["state"]?
      unless state
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: state")
      end

      # Ansible's argument spec: state choices are enabled,
      # disabled, present, absent - anything else fails at argument
      # validation time, before any firewalld interaction (verified
      # live: "value of state must be one of: absent, disabled, enabled,
      # present, got: enabled-forever"). This plugin previously
      # accepted any other value as a silent "disabled".
      unless %w[enabled disabled present absent].includes?(state)
        return PluginResult.new(changed: false, failed: true, msg: "value of state must be one of: absent, disabled, enabled, present, got: #{state}")
      end

      # Real firewalld.py's first module-level act is
      # FirewallTransaction.sanity_check() - the firewall Python
      # library's import gate (the Ansible module: the import
      # block sets import_failure=True, sanity_check turns that into
      # missing_required_lib('firewall') + the version suffix). It
      # runs BEFORE the offline/permanent validation and the zone
      # resolution, so a target without the python3-firewall bindings
      # fails with that exact message regardless of anything else.
      if gate = Krikri.missing_python_library("firewall", "firewall.config")
        return PluginResult.new(changed: false, failed: true,
          msg: "#{gate[:msg]}. Version 0.2.11 or newer required (0.3.9 or newer for offline operations)")
      end

      zone = resolve_zone
      unless zone
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: zone (and no default zone could be determined)")
      end

      if validation_error = validate_permanent_immediate(zone)
        return validation_error
      end

      # Ansible's own mutually_exclusive constraint spans target
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

      # Ansible's own validation ("absent and present state can
      # only be used in zone level operations" - verified live against
      # a `ansible-playbook`/`ansible.posix.firewalld` run):
      # `present`/`absent` are only valid for zone-level operations -
      # in the Ansible module's main() that means a bare zone: with NO
      # "thing" param at all (ZoneTransaction: creates/deletes the zone
      # itself - round900593 Thulium-Drake.firewalld found this engine
      # rejecting exactly that) or `target:` (handled above). Any other
      # "thing" - service/port/rich_rule/port_forward/etc - requires
      # `enabled`/`disabled` instead. Found live testing `port_forward:`
      # against Ansible in a round-34 host round: this plugin
      # previously accepted `present`/`absent` as silent synonyms for
      # every thing, more lenient than Ansible rather than matching
      # it.
      if state == "present" || state == "absent"
        thing_present = (PluginHelpers::FirewalldCommand::SUPPORTED_THINGS + ["port_forward"]).any? { |key| @params[key]? }
        return run_zone_transaction(zone, state) unless thing_present
        return PluginResult.new(changed: false, failed: true, msg: "absent and present state can only be used in zone level operations")
      end

      if port_forward = @params["port_forward"]?
        return run_port_forward(zone, state, port_forward)
      end

      if thing = PluginHelpers::FirewalldCommand.thing(@params)
        key, value = thing
        return run(zone, state, key, value)
      end

      # Zero "things" is NOT an error: verified live, Ansible with
      # only zone+state (enabled, permanent) succeeds as a no-op
      # (changed=false) - its transaction list is simply empty, so the
      # msgs list stays empty too and exit_json(msg='') keeps the EMPTY
      # msg key (an explicit kwarg). Only the offline note can occupy it
      # (see #firewalld_success).
      firewalld_success(false)
    end

    # Ansible never includes a `zone` key in any firewalld result
    # (its exit_json/fail_json calls pass changed/msg only), so none of
    # the result builders below emit one.

    # The success shape: changed, msg, failed - Ansible's
    # exit_json(changed=changed, msg=', '.join(msgs)) with the empty-msg
    # key kept only when msgs is empty (an explicit msg='' kwarg).
    private def firewalld_success(changed : Bool) : PluginResult
      if @fw_offline
        @msgs << "(offline operation: only on-disk configs were altered)"
      end
      if @msgs.empty?
        PluginResult.new(changed: changed, failed: false, msg: "", include_empty_msg: true)
      else
        PluginResult.new(changed: changed, failed: false, msg: @msgs.join(", "))
      end
    end

    # Check-mode change: Ansible's transaction run() calls
    # exit_json(changed=True) outright - NO msg key at all (registered
    # shape: changed, failed only, round994003 firewalld_service_check).
    private def check_mode_changed_result : PluginResult
      PluginResult.new(changed: true, failed: false)
    end

    # Ansible's action_handler wraps every
    # firewalld interaction in try/except and fail_json's with
    # "ERROR: Exception caught: <exception>" plus, when any context msgs
    # have accumulated, " <joined msgs>"; a message mentioning
    # INVALID_SERVICE first earns the module's own /etc/services hint
    # line. <exception> is the str() of the raised error: a D-Bus error
    # from the live-daemon path carries the "org.fedoraproject.
    # FirewallD1.Exception: " error-name prefix (round994003
    # firewalld_fail), while the offline Python's local FirewallError
    # does not.
    private def firewalld_exception_failure(error_core : String) : PluginResult
      if error_core.includes?("INVALID_SERVICE")
        @msgs << "Services are defined by port/tcp relationship and named as they are in /etc/services (on most systems)"
      end
      exception = @fw_offline ? error_core : "org.fedoraproject.FirewallD1.Exception: #{error_core}"
      msg = @msgs.empty? ? "ERROR: Exception caught: #{exception}" : "ERROR: Exception caught: #{exception} #{@msgs.join(", ")}"
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # The CLI tools report their errors on STDERR with an empty stdout
    # ("Error: <core>" for most, a bare "<core>" for some offline
    # service paths) - feeding the empty stdout into the result msg is
    # what made every krikri firewalld failure on the round994003 real
    # host msg-less. Strip the optional prefix and wrap the core the way
    # Ansible's action_handler does.
    private def command_failure_result(result) : PluginResult
      core = result[:stderr].to_s.strip
      core = result[:stdout].to_s.strip if core.empty?
      firewalld_exception_failure(core.lchop("Error: ").strip)
    end

    # The context line each real transaction appends to msgs right after
    # its get_enabled probes, before any mutation.
    private def append_operation_context_msg : Nil
      @msgs << if @do_runtime && @do_permanent
        "Permanent and Non-Permanent(immediate) operation"
      elsif @do_runtime
        "Non-permanent operation"
      else
        "Permanent operation"
      end
    end

    # The per-change detail line, in Ansible's composition order: the
    # service/port/rich_rule/protocol/icmp-block(-inversion)/port_forward
    # messages come from main() after the transaction returns, while
    # source/interface/masquerade/forward carry their own
    # enabled_msg/disabled_msg inside the transaction itself. nil for the
    # things real composes no change line for (icmp_block_inversion,
    # target).
    private def thing_changed_msg(zone : String, key : String, value : String, want_present : Bool) : String?
      state = want_present ? "enabled" : "disabled"
      # main()'s own "Changed <thing> <value> to <state>" lines...
      value_msgs = {
        "service"    => "Changed service #{value} to #{state}",
        "port"       => "Changed port #{value} to #{state}",
        "rich_rule"  => "Changed rich_rule #{value} to #{state}",
        "protocol"   => "Changed protocol #{value} to #{state}",
        "icmp_block" => "Changed icmp-block #{value} to #{state}",
        # ...and the transactions that carry their own
        # enabled_msg/disabled_msg (appended inside run(), before main()'s
        # tail). icmp_block_inversion sets neither; target is composed by
        # #run_target and port_forward by #run_port_forward.
        "source"     => want_present ? "Added #{value} to zone #{zone}" : "Removed #{value} from zone #{zone}",
        "interface"  => want_present ? "Changed #{value} to zone #{zone}" : "Removed #{value} from zone #{zone}",
        "masquerade" => want_present ? "Added masquerade to zone #{zone}" : "Removed masquerade from zone #{zone}",
        "forward"    => want_present ? "Added forward to zone #{zone}" : "Removed forward from zone #{zone}",
      }
      value_msgs[key]?
    end

    private def run_target(zone : String, state : String, target : String) : PluginResult
      # Ansible's own ZoneTargetTransaction FAILS any target change
      # in the immediate (runtime) context - a zone's target is only
      # settable permanently ("Zone operations must be permanent. Make
      # sure you didn't set the 'permanent' flag to 'false' or the
      # 'immediate' flag to 'true.'" - the Ansible module's own
      # tx_not_permanent_error_msg, raised by BOTH
      # set_enabled_immediate and set_disabled_immediate). So even a
      # bare `target:` task (immediate silently forced true) fails under
      # Ansible, and one with permanent+immediate fails too - the
      # immediate transaction runs first. Only permanent-only requests
      # proceed.
      if @do_runtime
        return PluginResult.new(changed: false, failed: true, msg: "Zone operations must be permanent. Make sure you didn't set the 'permanent' flag to 'false' or the 'immediate' flag to 'true'.")
      end

      want_present = state == "enabled" || state == "present"
      desired = want_present ? target : "default"

      content = read_zone_xml(zone)
      return firewalld_exception_failure("INVALID_ZONE: #{zone}") unless content

      append_operation_context_msg
      return firewalld_success(false) if zone_target(content) == desired

      return check_mode_changed_result if true?(@params["_ansible_check_mode"]?)

      write_zone_xml(zone, PluginHelpers::FirewalldCommand.zone_set_target(content, desired))
      # Ansible's own ZoneTargetTransaction enabled/disabled msgs.
      @msgs << (want_present ? "Set zone #{zone} target to #{target}" : "Reset zone #{zone} target to default")
      firewalld_success(true)
    end

    # The zone root's target attribute - a zone's target isn't optional
    # the way an entry is, its ABSENCE is the "default" target (see the
    # class comment on state: disabled/absent resetting to "default").
    private def zone_target(content : String) : String
      root = KXML.parse(content).root
      return "default" unless root && root.local_name == "zone"
      root.attribute("target").try(&.value) || "default"
    end

    # The bare `zone:` + `state: present/absent` operation - real
    # Ansible's own ZoneTransaction (permanent-only; every immediate
    # variant fails with the same tx_not_permanent_error_msg run_target
    # raises). present creates the zone when missing and is idempotent
    # (changed=false) when it already exists; absent deletes the /etc
    # zone file, is a no-op for a missing zone, and fails with real
    # firewalld's own BUILTIN_ZONE error for a zone that only exists as
    # a /usr/lib stock zone (firewalld's fw_config.remove_zone refuses
    # to touch builtin zones - verified against its source). The created
    # zone file is `<zone>` with no target attribute, matching what
    # `firewall-cmd --permanent --new-zone=` itself writes (firewalld's
    # zone_writer omits target when it equals the DEFAULT_ZONE_TARGET
    # sentinel).
    private def run_zone_transaction(zone : String, state : String) : PluginResult
      if @do_runtime
        return PluginResult.new(changed: false, failed: true, msg: "Zone operations must be permanent. Make sure you didn't set the 'permanent' flag to 'false' or the 'immediate' flag to 'true'.")
      end

      want_present = state == "present"
      exists = read_zone_xml(zone) ? true : false

      append_operation_context_msg
      return firewalld_success(false) if exists == want_present
      return check_mode_changed_result if true?(@params["_ansible_check_mode"]?)

      if want_present
        write_zone_xml(zone, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<zone>\n</zone>\n")
        # Ansible's own ZoneTransaction enabled msg, then main()'s detail line.
        @msgs << "Added zone #{zone}"
      else
        etc_path = File.join(ETC_ZONE_DIR, "#{zone}.xml")
        if File.exists?(etc_path)
          File.delete(etc_path)
          @msgs << "Removed zone #{zone}"
        else
          return PluginResult.new(changed: false, failed: true, msg: "BUILTIN_ZONE: '#{zone}' is built-in zone")
        end
      end
      @msgs << "Changed zone #{zone} to #{state}"
      firewalld_success(true)
    end

    # Matches Ansible's own `ForwardPortTransaction` construction
    # exactly: fails on >1 entries, requires port/proto/toport (checked
    # in that order, matching the Ansible module's own error-message
    # order), `toaddr` optional and simply omitted from the compound
    # value when absent.
    private def run_port_forward(zone : String, state : String, raw : String) : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      entries = JSON.parse(raw).as_a
      return PluginResult.new(changed: false, failed: true, msg: "Only one port forward supported at a time") if entries.size > 1
      return firewalld_success(false) if entries.empty?

      built = PluginHelpers::FirewalldCommand.port_forward_value(entries[0])
      return PluginResult.new(changed: false, failed: true, msg: built[:error] || "invalid port_forward value") unless value = built[:value]

      want_present = state == "enabled"
      check_mode = true?(@params["_ansible_check_mode"]?)
      runtime_present : Bool? = nil
      permanent_plan : NamedTuple(content: String, element: String, attrs: Hash(String, String), present: Bool)? = nil

      if @do_runtime
        query = remote_exec(PluginHelpers::FirewalldCommand.forward_port_query_command(zone, value, "firewall-cmd"))
        return command_failure_result(query) unless {0, 1}.includes?(query[:exit_code])
        runtime_present = query[:exit_code] == 0
      end

      if @do_permanent
        content = read_zone_xml(zone)
        return firewalld_exception_failure("INVALID_ZONE: #{zone}") unless content
        element, attrs = PluginHelpers::FirewalldCommand.forward_port_element(entries[0])
        permanent_plan = {content: content, element: element, attrs: attrs,
                          present: PluginHelpers::FirewalldCommand.zone_query(content, element, attrs)}
      end

      append_operation_context_msg
      changed = false

      runtime_present.try do |present|
        next if present == want_present
        return check_mode_changed_result if check_mode
        cmd = want_present ? PluginHelpers::FirewalldCommand.forward_port_add_command(zone, value, "firewall-cmd") : PluginHelpers::FirewalldCommand.forward_port_remove_command(zone, value, "firewall-cmd")
        result = remote_exec(cmd)
        return command_failure_result(result) if result[:exit_code] != 0
        changed = true
      end

      if plan = permanent_plan
        if plan[:present] != want_present
          return check_mode_changed_result if check_mode
          new_content = want_present ? PluginHelpers::FirewalldCommand.zone_add(plan[:content], plan[:element], plan[:attrs]) : PluginHelpers::FirewalldCommand.zone_remove(plan[:content], plan[:element], plan[:attrs])
          if new_content
            write_zone_xml(zone, new_content)
            changed = true
          end
        end
      end

      # Ansible's ForwardPortTransaction sets no enabled/disabled msg; the
      # detail line comes from main(), keyed on the ORIGINAL dict values
      # with toaddr always spelled out (empty when absent).
      if changed
        entry = entries[0]
        toaddr = entry["toaddr"]?.try(&.to_s) || ""
        compound = "port=#{entry["port"]}:proto=#{entry["proto"]}:toport=#{entry["toport"]}:toaddr=#{toaddr}"
        @msgs << "Changed port_forward #{compound} to #{state}"
      end
      firewalld_success(changed)
    end

    private def run(zone : String, state : String, key : String, value : String) : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      want_present = state == "enabled"
      check_mode = true?(@params["_ansible_check_mode"]?)
      runtime_present : Bool? = nil
      rich_permanent_present : Bool? = nil
      permanent_plan : NamedTuple(content: String, element: String, attrs: Hash(String, String), present: Bool)? = nil

      if @do_runtime
        if key == "service"
          # Ansible's ServiceTransaction.get_enabled_immediate reads the
          # zone's whole service LIST and tests membership, so a name
          # that is not a defined service simply reads as "not
          # enabled" here - the failure comes from the later add, with
          # the daemon's own zone context. See
          # FirewalldCommand.zone_service_list_command's comment.
          query = remote_exec(PluginHelpers::FirewalldCommand.zone_service_list_command(zone, "firewall-cmd"))
          return command_failure_result(query) unless query[:exit_code] == 0
          runtime_present = PluginHelpers::FirewalldCommand.service_list(query[:stdout]).includes?(value)
        else
          query = remote_exec(PluginHelpers::FirewalldCommand.query_command(zone, key, value, "firewall-cmd"))
          # firewall-cmd's query flags exit 0 ("yes")/1 ("no"); anything
          # else is a real error and is what Ansible's
          # action_handler would have caught.
          return command_failure_result(query) unless {0, 1}.includes?(query[:exit_code])
          runtime_present = query[:exit_code] == 0
        end
      end

      if @do_permanent
        if key == "rich_rule"
          query = remote_exec(PluginHelpers::FirewalldCommand.query_command(zone, "rich_rule", value))
          return command_failure_result(query) unless {0, 1}.includes?(query[:exit_code])
          rich_permanent_present = query[:exit_code] == 0
        else
          content = read_zone_xml(zone)
          return firewalld_exception_failure("INVALID_ZONE: #{zone}") unless content
          element, attrs = PluginHelpers::FirewalldCommand.zone_element(key, value)
          permanent_plan = {content: content, element: element, attrs: attrs,
                            present: PluginHelpers::FirewalldCommand.zone_query(content, element, attrs)}
        end
      end

      append_operation_context_msg
      changed = false

      # Ansible's transaction adds PERMANENTLY before immediately, and the
      # permanent add is what validates the service name: real firewalld's
      # own config-zone addService -> update() runs check_config, which
      # raises INVALID_SERVICE "Zone '<zone>': '<service>' not among
      # existing services" for a name no service XML defines (firewalld
      # src/firewall/core/io/policy.py's common_check_config; the message
      # reaches the module as the D-Bus error
      # org.fedoraproject.FirewallD1.Exception - round996006
      # firewalld_fail, which registered the context msg above plus the
      # module's own /etc/services hint). Krikri writes the zone XML
      # itself, so it has to run that check explicitly: without it this
      # plugin silently wrote a <service name="kop_nosuch_svc"/> entry
      # into the zone file instead of failing. Never in check mode:
      # real exits_json(changed=True) right after the context msg there,
      # before the permanent leg ever runs.
      if !check_mode && key == "service" && want_present && (plan = permanent_plan) && !plan[:present]
        unless service_defined?(value)
          return firewalld_exception_failure("INVALID_SERVICE: Zone '#{zone}': '#{value}' not among existing services")
        end
      end

      runtime_present.try do |present|
        next if present == want_present
        return check_mode_changed_result if check_mode
        cmd = want_present ? PluginHelpers::FirewalldCommand.add_command(zone, key, value, "firewall-cmd") : PluginHelpers::FirewalldCommand.remove_command(zone, key, value, "firewall-cmd")
        result = remote_exec(cmd)
        return command_failure_result(result) if result[:exit_code] != 0
        changed = true
      end

      rich_permanent_present.try do |present|
        next if present == want_present
        return check_mode_changed_result if check_mode
        cmd = want_present ? PluginHelpers::FirewalldCommand.add_command(zone, "rich_rule", value) : PluginHelpers::FirewalldCommand.remove_command(zone, "rich_rule", value)
        result = remote_exec(cmd)
        return command_failure_result(result) if result[:exit_code] != 0
        changed = true
      end

      if plan = permanent_plan
        if plan[:present] != want_present
          return check_mode_changed_result if check_mode
          new_content = want_present ? PluginHelpers::FirewalldCommand.zone_add(plan[:content], plan[:element], plan[:attrs]) : PluginHelpers::FirewalldCommand.zone_remove(plan[:content], plan[:element], plan[:attrs])
          if new_content
            write_zone_xml(zone, new_content)
            changed = true
          end
        end
      end

      if changed && (detail = thing_changed_msg(zone, key, value, want_present))
        @msgs << detail
      end
      firewalld_success(changed)
    end

    # Writes back to /etc/firewalld/zones/<zone>.xml - Ansible's
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

    # Does firewalld define this service at all (a service XML in
    # either catalogue dir)? The check Ansible's own permanent
    # config-zone update() performs before it accepts a zone that
    # references the name - see the INVALID_SERVICE comment in #run.
    private def service_defined?(name : String) : Bool
      return false if name.empty? || name.includes?("/") || name.includes?("..")

      SERVICE_DIRS.any? { |dir| File.exists?(File.join(dir, "#{name}.xml")) }
    end

    # `zone:` (Ansible's own doc: "the default zone can be
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

    # Ports Ansible's own `permanent`/`immediate`/`offline` twisty
    # validation logic (the Ansible module's
    # `main()`) instead of the previous blanket "offline: true,
    # permanent: true both required" gate - that combination isn't even
    # a Ansible requirement (permanent defaults false, immediate
    # defaults false, offline defaults false; when neither permanent nor
    # immediate is given, immediate is silently forced true). Returns a
    # failed PluginResult exactly matching Ansible's own error
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
          return PluginResult.new(changed: false, failed: true, msg: "offline cannot be enabled unless permanent changes are allowed")
        end
        immediate = false if fw_offline
      end

      immediate = true if !permanent && !immediate

      if immediate && fw_offline
        return PluginResult.new(changed: false, failed: true, msg: "firewall is not currently running, unable to perform immediate actions without a running firewall daemon")
      end

      # Which contexts this request touches: an immediate action against
      # a live daemon goes through `firewall-cmd` (the D-Bus client CLI,
      # the same channel Ansible's own firewall module drives), a
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
