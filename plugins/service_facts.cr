#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # ServiceFacts plugin - populates the ansible_facts.services dict,
  # matching ansible.builtin.service_facts. The fact shape follows real
  # Ansible: a dict keyed by unit name (`"sshd.service"`) with
  # {name, source, state, status}.
  #
  # systemd-only (every real caller in this codebase's tested roles
  # targets a systemd host; real Ansible also supports sysvinit/upstart/
  # AIX SRC, none implemented here). Combines `systemctl list-unit-files`
  # (every known unit, enabled/disabled/static/masked - "status") with
  # `systemctl list-units` (only currently loaded units - "state":
  # running/stopped, from the unit's own SUB column) - a unit present in
  # the first but not the second is reported "state": "stopped", matching
  # real Ansible's own behavior for an installed-but-inactive service.
  #
  # Read-only, so it's safe under --check.
  class ServiceFactsPlugin < BasePlugin
    def execute : PluginResult
      unit_files = list_unit_files
      active_states = list_active_states

      services = Hash(String, JSON::Any).new
      unit_files.each do |name, status|
        state = active_states[name]? || "stopped"
        services[name] = JSON::Any.new({
          "name"   => JSON::Any.new(name),
          "source" => JSON::Any.new("systemd"),
          "state"  => JSON::Any.new(state),
          "status" => JSON::Any.new(status),
        })
      end

      PluginResult.new(
        changed: false,
        failed: false,
        msg: "Gathered #{services.size} service facts",
        ansible_facts: JSON::Any.new({"services" => JSON::Any.new(services)})
      )
    end

    # "UNIT_FILE STATE [VENDOR PRESET]" per line, e.g.
    # "sshd.service enabled enabled".
    private def list_unit_files : Hash(String, String)
      result = Hash(String, String).new
      capture("systemctl", ["list-unit-files", "--type=service", "--no-legend", "--no-pager"]).each_line do |line|
        parts = line.split(/\s+/)
        next if parts.size < 2
        result[parts[0]] = parts[1]
      end
      result
    end

    # "UNIT LOAD ACTIVE SUB DESCRIPTION" per line, e.g.
    # "sshd.service loaded active running OpenSSH server".
    private def list_active_states : Hash(String, String)
      result = Hash(String, String).new
      capture("systemctl", ["list-units", "--type=service", "--all", "--no-legend", "--no-pager"]).each_line do |line|
        parts = line.split(/\s+/)
        next if parts.size < 4
        result[parts[0]] = parts[3] == "running" ? "running" : "stopped"
      end
      result
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

plugin = CrystalPlay::ServiceFactsPlugin.new(config)
plugin.run
