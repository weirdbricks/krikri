#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/service_facts_parser"

module Krikri
  # ServiceFacts plugin - populates the ansible_facts.services dict,
  # matching ansible.builtin.service_facts. The fact shape follows real
  # Ansible: a dict keyed by unit name (`"sshd.service"`) with
  # {name, source, state, status}.
  #
  # Real Ansible runs its SysV scan and its systemd scan BOTH, merging
  # the two with systemd's entries winning, and - critically - reports
  # the task SKIPPED ("Failed to find any services...") when the merged
  # result is empty rather than handing back an empty dict. This plugin
  # was systemd-only and did neither: on a host where systemd is not PID
  # 1 it returned `ansible_facts.services = {}` with failed=false, so a
  # role gating on `'nginx.service' in ansible_facts.services` silently
  # took the wrong branch - no error, no failed task. Same shape as the
  # `service:` module's own systemd assumption (fixed 0.9.727); found by
  # sweeping the other plugins for it.
  #
  # Implemented scans: systemd, and SysV via `service --status-all`
  # (real Ansible's own guard: only when a `service` binary exists and
  # neither chkconfig nor rc-status does). Real Ansible's remaining
  # branches - upstart's `initctl list`, RedHat's chkconfig listing, and
  # OpenRC's `rc-status` - are not implemented; on such a host the
  # systemd scan still runs, and if it finds nothing the task is
  # correctly reported skipped rather than silently empty.
  #
  # The systemd scan combines `systemctl list-unit-files`
  # (every known unit, enabled/disabled/static/masked - "status") with
  # `systemctl list-units` (only currently loaded units - "state":
  # running/stopped, from the unit's own SUB column) - a unit present in
  # the first but not the second is reported "state": "stopped", matching
  # real Ansible's own behavior for an installed-but-inactive service.
  #
  # Read-only, so it's safe under --check.
  class ServiceFactsPlugin < BasePlugin
    def execute : PluginResult
      # SysV first, systemd second - real Ansible's own module order, and
      # the reason it matters: a service with BOTH an init script and a
      # unit file must end up reported as source "systemd", which only
      # happens if the systemd pass overwrites the sysv one.
      services = gather_sysv
      gather_systemd.each { |name, entry| services[name] = entry }

      # Real Ansible skips rather than returning an empty dict, so a role
      # can tell "no services found" apart from "this host genuinely runs
      # none" - and, more importantly, so a downstream `in
      # ansible_facts.services` test doesn't quietly read as false
      # against a fact that was never gathered.
      if services.empty?
        return PluginResult.new(
          changed: false,
          failed: false,
          msg: "Failed to find any services. This can be due to privileges or some other configuration issue.",
          skipped: true
        )
      end

      PluginResult.new(
        changed: false,
        failed: false,
        msg: "Gathered #{services.size} service facts",
        ansible_facts: JSON::Any.new({"services" => JSON::Any.new(services)})
      )
    end

    # Real Ansible's two passes, in its order and with its merge rules:
    # `list-units --all` first (the ONLY listing that carries units with
    # no unit file - generated, transient and template-instance units),
    # then `list-unit-files --all` to fill in each unit's real
    # enabled/disabled "status" and to add units that exist on disk but
    # were never loaded.
    #
    # This plugin previously keyed off unit FILES alone and looked state
    # up from list-units, which is the inverse: every loaded-but-fileless
    # unit was missing from the facts entirely (150 vs 130 units on a
    # plain Debian trixie systemd host), and a unit-file-only entry got a
    # flat "stopped" where real Ansible reports its raw ActiveState.
    private def gather_systemd : Hash(String, JSON::Any)
      services = Hash(String, JSON::Any).new
      return services unless systemd_managed?

      units = PluginHelpers::ServiceFactsParser.parse_units(
        capture("systemctl", ["list-units", "--no-pager", "--type", "service", "--all", "--plain"])
      )
      units.each do |name, entry|
        services[name] = systemd_entry(name, entry[:state], entry[:status])
      end

      unit_files = PluginHelpers::ServiceFactsParser.parse_unit_file_states(
        capture("systemctl", ["list-unit-files", "--no-pager", "--type", "service", "--all"])
      )

      # Units known only from their file have no state in either listing,
      # so real Ansible asks systemd directly for each one - batched into
      # a single call here (see the parser's own comments).
      unlisted = unit_files.keys.reject { |name| services.has_key?(name) }
      active_states = show_active_states(unlisted)

      unit_files.each do |name, status|
        if existing = services[name]?
          # A bad state (not-found/masked/failed) outranks the unit
          # file's own enabled/disabled - real Ansible keeps it.
          next if PluginHelpers::ServiceFactsParser::BAD_STATES.includes?(existing["status"].as_s)
          services[name] = systemd_entry(name, existing["state"].as_s, status)
        else
          services[name] = systemd_entry(name, active_states[name]? || "unknown", status)
        end
      end

      services
    end

    # One batched `systemctl show` where possible, falling back to one
    # call per unit if the batch comes back short - a unit that vanished
    # between the listing and the query, or any other reason systemctl
    # declines the whole argument list, must not silently turn every
    # unit's state into "unknown" (it did: one un-showable template unit
    # in the list zeroed all 43 file-only units on a stock Debian host).
    private def show_active_states(names : Array(String)) : Hash(String, String)
      showable = names.select { |name| PluginHelpers::ServiceFactsParser.showable_unit?(name) }
      return Hash(String, String).new if showable.empty?

      output = capture("systemctl", ["show"] + showable + ["--property=ActiveState"])
      if states = PluginHelpers::ServiceFactsParser.parse_show_active_states(output, showable)
        return states
      end

      result = Hash(String, String).new
      showable.each do |name|
        one = capture("systemctl", ["show", name, "--property=ActiveState"])
        if states = PluginHelpers::ServiceFactsParser.parse_show_active_states(one, [name])
          result[name] = states[name]
        end
      end
      result
    end

    private def systemd_entry(name : String, state : String, status : String) : JSON::Any
      JSON::Any.new({
        "name"   => JSON::Any.new(name),
        "source" => JSON::Any.new("systemd"),
        "state"  => JSON::Any.new(state),
        "status" => JSON::Any.new(status),
      })
    end

    # Real Ansible's guard, not just "is there a service binary": chkconfig
    # or rc-status present means the host is RedHat-style or OpenRC, whose
    # own (unimplemented here) scans own those services instead - running
    # `service --status-all` there would report a different, overlapping
    # set under the wrong source.
    private def gather_sysv : Hash(String, JSON::Any)
      services = Hash(String, JSON::Any).new
      return services unless which("service")
      return services if which("chkconfig") || which("rc-status")

      PluginHelpers::ServiceFactsParser.parse_sysv_status_all(
        capture("service", ["--status-all"])
      ).each do |name, state|
        # No "status" key: real Ansible's sysv scan reports name/state/
        # source only - it has no enabled/disabled information to give.
        services[name] = JSON::Any.new({
          "name"   => JSON::Any.new(name),
          "source" => JSON::Any.new("sysv"),
          "state"  => JSON::Any.new(state),
        })
      end
      services
    end

    # module_utils' own `is_systemd_managed`: systemctl present, then
    # systemd's documented sd_booted canaries, then /proc/1/comm. NOT
    # merely "systemctl exists" - see plugins/service.cr for the same
    # check and why the distinction is the whole bug.
    private def systemd_managed? : Bool
      return false unless which("systemctl")
      return true if {"/run/systemd/system/", "/dev/.run/systemd/", "/dev/.systemd/"}.any? { |canary| File.exists?(canary) || Dir.exists?(canary) }
      File.read("/proc/1/comm").strip == "systemd" rescue false
    end

    private def which(binary : String) : Bool
      search = (ENV["PATH"]?.try(&.split(':')) || [] of String) + ["/sbin", "/usr/sbin", "/bin", "/usr/bin"]
      search.any? { |dir| File.exists?(File.join(dir, binary)) }
    end

    private def capture(command : String, args : Array(String)) : String
      output = IO::Memory.new
      Process.run(command, args, output: output, error: Process::Redirect::Close)
      output.to_s
    rescue
      ""
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::ServiceFactsPlugin.new(config)
plugin.run
