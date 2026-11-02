#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Seport plugin - manages an SELinux port type mapping via `semanage
  # port`. Compatible with Ansible's community.general.seport (verified
  # shape against ansible-playbook's own module docs; found missing
  # entirely - round171's robertdebock.haproxy - which silently dropped
  # the whole gated task instead of resolving it, since a task whose
  # module has no plugin never even reaches its own when: evaluation
  # here).
  #
  # Real seport.py binds libselinux/libsemanage directly; this shells
  # out to `semanage port` instead, matching this codebase's general
  # SELinux/RPM CLI-tool approach (see seboolean.cr/rpm_key.cr).
  #
  # Supported parameters:
  # - ports: required. A single port/range or a comma-separated list
  #   (e.g. "80", "80-81", "80,443").
  # - proto: required. tcp/udp/dccp/sctp (Ansible's choices; case-sensitive,
  #   like Ansible's argument_spec check).
  # - setype: required. The SELinux port type to assign.
  # - state: default "present". present adds/reassigns the mapping;
  #   absent removes it (only if it currently belongs to setype).
  # - ignore_selinux_state: default false. Skips the "SELinux enabled"
  #   pre-check.
  class SeportPlugin < BasePlugin
    def execute : PluginResult
      ports_param = @params["ports"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: ports") unless ports_param

      proto = @params["proto"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: proto") unless proto

      setype = @params["setype"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: setype") unless setype

      setype = @params["setype"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: setype") unless setype

      # Ansible's argument_spec rejects these at module init - before the
      # python-lib import check, the SELinux-enabled gate, anything
      # (podman-diff harness R4/R5/R11: Ansible reports the proto/state
      # choices failure and the bool-conversion failure against a host
      # with no SELinux at all, while this plugin reached the
      # "SELinux is disabled" gate first, so an invalid value against a
      # real SELinux host would have slipped past validation).
      proto = proto.not_nil!
      unless ["tcp", "udp", "dccp", "sctp"].includes?(proto)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of proto must be one of: tcp, udp, dccp, sctp, got: #{proto}")
      end

      # Case-sensitive like Ansible's choices check (state: Present is a
      # real-args failure, not a silently-accepted alias).
      state = @params["state"]? || "present"
      unless ["absent", "present"].includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: absent, present, got: #{state}")
      end

      if bad_bool = @params["ignore_selinux_state"]?
        valid_booleans = {"true", "yes", "1", "on", "y", "t", "false", "no", "0", "off", "n", "f"}
        unless valid_booleans.includes?(bad_bool.downcase)
          return PluginResult.new(changed: false, failed: true,
            msg: "argument 'ignore_selinux_state' is of type <class 'str'> and we were unable to convert to bool: " \
                 "The value '#{bad_bool}' is not a valid boolean. " \
                 "Valid booleans include: 'f', 'y', 1, 0, 'yes', 'false', 'on', '1', 'n', 'off', 't', 'true', '0', 'no'")
        end
      end
      ignore_selinux_state = true?(@params["ignore_selinux_state"]?)

      unless ignore_selinux_state
        enforce = remote_exec("getenforce")
        if enforce[:exit_code] != 0 || enforce[:stdout].strip.downcase == "disabled"
          return PluginResult.new(changed: false, failed: true, msg: "SELinux is disabled on this host.")
        end
      end

      # ports comes through as a plain string for a scalar task param,
      # or Crystal's Array#to_s rendering ("[\"80\", \"443\"]") for a
      # YAML list - strip any of that formatting down to a bare
      # comma-separated port list either way.
      ports = ports_param.gsub(/[\[\]"]/, "").split(',').map(&.strip).reject(&.empty?)
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: ports") if ports.empty?

      listing = remote_exec("semanage port -l")
      unless listing[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to list SELinux port mappings: #{listing[:stderr]}")
      end

      # Real seport.py (supports_check_mode=True) answers "changed" from
      # read-only libsemanage queries alone and skips add/modify/delete in
      # check mode - the mutation commands must never run under --check.
      # This plugin shells out to `semanage`, so check mode has to be
      # honored here explicitly: otherwise a --check run both mutates the
      # host and hits the mutation paths' own failure modes (issue #757).
      check_mode = true?(@params["_ansible_check_mode"]?)

      # Real seport's queries work on (setype, proto) record lists whose
      # entries are ports or ranges ("22", "1024-32767"): state=present is
      # changed when the requested port/range is NOT fully covered by an
      # entry of the TARGET type (_port_is_covered over
      # get_all_by_type(setype, proto)), and state=absent is changed only
      # when the port is an exact entry of the target type. The old
      # containment-based "current type" lookup took the FIRST listing
      # line whose range contained the port - on modern EL hosts
      # reserved_port_t's 1-511 range sorts before ssh_port_t's exact
      # "22", so an already-mapped port 22 took the modify path (a
      # same-type semanage no-op that still reported changed), and a port
      # with no exact record but inside another type's range (4999 inside
      # unreserved_port_t's 1024-32767) took the modify path real semanage
      # rejects with "ValueError: Port tcp/4999 is not defined".
      records = parse_port_records(listing[:stdout])
      target_records = records.select do |record|
        record[:proto] == proto && record[:setype] == setype
      end

      changed = false
      ports.each do |port|
        request = parse_port_range(port)
        unless request
          # Real seport's _parse_port_range int() failure, wrapped by
          # fail_json's "ExceptionClass: message" prefix.
          return PluginResult.new(changed: changed, failed: true,
            msg: "ValueError: invalid literal for int() with base 10: '#{port}'\n")
        end

        if state == "absent"
          next unless target_records.any? { |record| record[:entry] == port }
          if check_mode
            changed = true
            next
          end
          result = remote_exec("semanage port -d -t #{shell_single_quote(setype)} -p #{shell_single_quote(proto)} #{shell_single_quote(port)}")
          unless result[:exit_code] == 0
            return PluginResult.new(changed: changed, failed: true, msg: "Failed to remove port #{port}/#{proto} from #{setype}: #{result[:stderr]}")
          end
          changed = true
        else
          next if target_records.any? { |record| record[:lo] <= request[:lo] && request[:hi] <= record[:hi] }
          if check_mode
            changed = true
            next
          end
          # Real seport picks add vs modify from an EXACT (low, high,
          # proto) record lookup (semanage_port_get_type), never from
          # range containment: a port with no exact record takes the add
          # path, which real semanage accepts even for ports an existing
          # policy range covers.
          exact = records.find { |record| record[:proto] == proto && record[:lo] == request[:lo] && record[:hi] == request[:hi] }
          flag = exact ? "-m" : "-a"
          result = remote_exec("semanage port #{flag} -t #{shell_single_quote(setype)} -p #{shell_single_quote(proto)} #{shell_single_quote(port)}")
          unless result[:exit_code] == 0
            return PluginResult.new(changed: changed, failed: true, msg: "Failed to set port #{port}/#{proto} to #{setype}: #{result[:stderr]}")
          end
          changed = true
        end
      end

      PluginResult.new(changed: changed, failed: false, msg: "")
    end

    # `semanage port -l` prints one type per line, e.g.
    # "http_port_t     tcp      80, 81, 443, 488, 1988, 8008, 8009, 8443, 9000"
    # - one record per port/range entry, with the entry kept verbatim for
    # real seport's exact-string absent comparison.
    private def parse_port_records(listing : String) : Array(NamedTuple(setype: String, proto: String, entry: String, lo: Int32, hi: Int32))
      records = [] of NamedTuple(setype: String, proto: String, entry: String, lo: Int32, hi: Int32)
      listing.each_line do |line|
        parts = line.split(/\s+/, 3)
        next if parts.size < 3
        setype, line_proto, port_list = parts[0], parts[1], parts[2]
        port_list.split(',').each do |entry|
          entry = entry.strip
          next if entry.empty?
          range = parse_port_range(entry)
          next unless range
          records << {setype: setype, proto: line_proto.downcase, entry: entry,
                      lo: range[:lo], hi: range[:hi]}
        end
      end
      records
    end

    # Real seport's _parse_port_range: a port or "low-high" range string
    # as (low, high); nil for anything int() would reject.
    private def parse_port_range(port : String) : NamedTuple(lo: Int32, hi: Int32)?
      parts = port.split("-", 2)
      lo = parts[0].to_i?
      return nil unless lo
      hi = parts.size == 2 ? parts[1].to_i? : lo
      return nil unless hi
      {lo: lo, hi: hi}
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::SeportPlugin.new(config)
plugin.run
