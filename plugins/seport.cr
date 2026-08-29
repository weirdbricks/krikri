#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Seport plugin - manages an SELinux port type mapping via `semanage
  # port`. Compatible with Ansible's community.general.seport (verified
  # shape against real ansible-playbook's own module docs; found missing
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
  # - proto: required. tcp/udp.
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

      state = @params["state"]?.try(&.downcase) || "present"
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

      changed = false
      ports.each do |port|
        current_type = current_type_for(listing[:stdout], port, proto)

        if state == "absent"
          next if current_type.nil? || current_type != setype
          result = remote_exec("semanage port -d -t #{setype} -p #{proto} #{port}")
          unless result[:exit_code] == 0
            return PluginResult.new(changed: changed, failed: true, msg: "Failed to remove port #{port}/#{proto} from #{setype}: #{result[:stderr]}")
          end
          changed = true
        else
          next if current_type == setype
          flag = current_type.nil? ? "-a" : "-m"
          result = remote_exec("semanage port #{flag} -t #{setype} -p #{proto} #{port}")
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
    # Returns the SELinux type currently owning *port* for *proto*, or
    # nil if it isn't mapped anywhere yet.
    private def current_type_for(listing : String, port : String, proto : String) : String?
      listing.each_line do |line|
        parts = line.split(/\s+/, 3)
        next if parts.size < 3
        setype, line_proto, port_list = parts[0], parts[1], parts[2]
        next unless line_proto.downcase == proto.downcase
        matches = port_list.split(',').map(&.strip).any? do |entry|
          if entry.includes?('-')
            lo, hi = entry.split('-', 2).map(&.to_i?)
            lo && hi && port.to_i? && lo <= port.to_i && port.to_i <= hi
          else
            entry == port
          end
        end
        return setype if matches
      end
      nil
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::SeportPlugin.new(config)
plugin.run
