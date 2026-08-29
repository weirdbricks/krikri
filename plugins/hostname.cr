#!/usr/bin/env crystal

# hostname module (ansible.builtin.hostname) - manages the system hostname.
#
# Sets the hostname persistently using systemd's hostnamectl (the expected
# mechanism on modern Linux - Ubuntu 16.04+, Debian 9+, etc.), with a
# fallback to /etc/hostname + the hostname(1) command for non-systemd
# systems.
#
# Idempotent: compares against the current hostname (System.hostname)
# before making any change. Returns ansible_facts (ansible_hostname,
# ansible_nodename, ansible_fqdn, ansible_domain) matching real Ansible's
# convention.
#
# Verified against real ansible-playbook behavior (not ansible-doc alone):
# - Returns ansible_facts at the result top level, not nested under a
#   separate key.
# - ansible_hostname is the short name (first component before '.').
# - ansible_fqdn falls back to the short name if hostname -f fails (returns
#   only "hostname: Name or service not known" stderr exit code 1 on hosts
#   with no FQDN configured), matching the facts module's own behavior.
# - check_mode reports would-change without executing hostnamectl.

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class HostnamePlugin < BasePlugin
    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      # Required param: name (the desired hostname)
      desired = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless desired

      current = System.hostname

      # Build facts (same shape as the facts plugin's gather_hostname)
      hostname_facts = build_facts(desired)

      if current == desired
        return PluginResult.new(
          changed: false,
          failed: false,
          ansible_facts: hostname_facts,
          msg: "hostname is already #{desired}",
        )
      end

      # Store old facts for diff
      old_facts = build_facts(current)

      if @check_mode
        return PluginResult.new(
          changed: true,
          failed: false,
          ansible_facts: hostname_facts,
          diff: generate_attribute_diff(old_facts, hostname_facts),
          msg: "would change hostname from #{current} to #{desired}",
        )
      end

      # Actually set the hostname
      set_hostname(desired)

      # Re-read to verify (and get the actual resulting hostname, since
      # hostnamectl may normalize it - trimming trailing dots, etc.)
      actual = System.hostname
      actual_facts = build_facts(actual)

      PluginResult.new(
        changed: true,
        failed: false,
        ansible_facts: actual_facts,
        diff: generate_attribute_diff(old_facts, actual_facts),
        msg: "hostname changed from #{current} to #{actual}",
      )
    end

    # Build the standard ansible hostname facts hash.
    # Matches the facts plugin's gather_hostname output structure exactly:
    # - ansible_hostname: short name (first label before the first '.');
    #   equals the full name when there is no dot.
    # - ansible_nodename:  the name passed in (the system's node name).
    # - ansible_fqdn:      the live system FQDN from `hostname -f`, falling
    #   back to ansible_hostname when hostname -f fails (hosts with no FQDN
    #   configured return exit 1 + stderr "Name or service not known",
    #   matching the facts module's own behavior).
    # - ansible_domain:    the suffix after the first '.' of the FQDN, or "".
    private def build_facts(hostname : String) : Hash(String, String)
      dot = hostname.index('.')
      short = dot ? hostname[0...dot] : hostname

      fqdn = begin
        output = capture("hostname", ["-f"]).strip
        output.empty? ? short : output
      rescue
        short
      end

      dot_fqdn = fqdn.index('.')
      domain = dot_fqdn ? fqdn[(dot_fqdn + 1)..] : ""

      {
        "ansible_hostname" => short,
        "ansible_nodename" => hostname,
        "ansible_fqdn"     => fqdn,
        "ansible_domain"   => domain,
      }
    end

    # Set the system hostname persistently.
    # Tries hostnamectl first (systemd), falls back to /etc/hostname +
    # hostname(1) for non-systemd systems.
    private def set_hostname(name : String) : Nil
      # Try systemd's hostnamectl first - detect failure via exit status.
      # capture swallows errors and returns "", so a failed hostnamectl call
      # is indistinguishable from an empty-stdout success on its own; the
      # status check below is what actually drives the fallback.
      if run_succeeds?("hostnamectl", ["set-hostname", name])
        return
      end

      # Legacy fallback: write /etc/hostname and run hostname(1)
      File.write("/etc/hostname", name + "\n")
      capture("hostname", [name])
    end

    # Run *command* with *args* directly (no shell). Returns true iff the
    # process exited 0 (binary found and succeeded). stderr is discarded; a
    # missing binary or nonzero exit => false.
    private def run_succeeds?(command : String, args : Array(String) = [] of String) : Bool
      status = Process.run(command, args, error: Process::Redirect::Close)
      status.success?
    rescue
      false
    end

    # Run *command* with *args* directly (no shell), capturing stdout only
    # (stderr discarded). Returns "" if the binary can't be found or
    # execution otherwise fails - matches facts.cr's/service_facts.cr's own
    # `capture` helper (the plugin binary itself already executes on the
    # target host, so a plain local Process.run is correct here, not
    # remote_exec).
    private def capture(command : String, args : Array(String) = [] of String) : String
      output = IO::Memory.new
      Process.run(command, args, output: output, error: Process::Redirect::Close)
      output.to_s
    rescue
      ""
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::HostnamePlugin.new(config)
plugin.run
