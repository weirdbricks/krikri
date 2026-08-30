#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # community.general.capabilities - manages Linux file capabilities via
  # getcap(8)/setcap(8). Ported from the real Python module
  # (community/general/plugins/modules/capabilities.py) - same getcap
  # output parsing (both the older `/path = cap+ep` form and the newer
  # `/path cap+ep` form, including comma-grouped caps sharing one op/
  # flags pair), same "replace the entry for this cap name, keep every
  # other entry as-is" update semantics for both state: present/absent.
  #
  # Found needed live benchmarking prometheus.prometheus.blackbox_exporter
  # (round 27) - its own "Ensure blackbox exporter binary has cap_net_raw
  # capability" task (grants CAP_NET_RAW so the exporter can send raw
  # ICMP probes without running as root) had no plugin at all, silently
  # skipped with "Plugin not available: community.general.capabilities".
  class CapabilitiesPlugin < BasePlugin
    OPS = {"=", "-", "+"}
    alias Cap = Tuple(String, String?, String?)

    class CapError < Exception
    end

    def execute : PluginResult
      path = (@params["path"]? || @params["key"]?).try { |raw| expand_tilde(raw) }
      capability = @params["capability"]? || @params["cap"]?
      state = @params["state"]? || "present"
      check_mode = true?(@params["check_mode"]?)

      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path") unless path
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: capability") unless capability

      path = path.strip
      capability = capability.strip.downcase

      cap_name, cap_op, cap_flags = parse_cap(capability, op_required: state == "present")
      current_caps = getcap(path)
      cap_names = current_caps.map { |itm| itm[0] }

      if state == "present" && !current_caps.includes?({cap_name, cap_op, cap_flags})
        new_caps = current_caps.reject { |itm| itm[0] == cap_name }
        new_caps << {cap_name, cap_op, cap_flags}
        apply_caps(path, new_caps, state, check_mode)
      elsif state == "absent" && cap_names.includes?(cap_name)
        new_caps = current_caps.reject { |itm| itm[0] == cap_name }
        apply_caps(path, new_caps, state, check_mode)
      else
        PluginResult.new(changed: false, failed: false, msg: "capabilities unchanged", state: state)
      end
    rescue ex : CapError
      PluginResult.new(changed: false, failed: true, msg: ex.message || "capabilities module error")
    end

    # Commit the new capability set (or just report it, in check mode)
    private def apply_caps(path : String, new_caps : Array(Cap), state : String, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: true, failed: false, msg: "capabilities changed") if check_mode

      stdout = setcap(path, new_caps)
      PluginResult.new(changed: true, failed: false, msg: "capabilities changed", state: state, stdout: stdout)
    end

    private def getcap(path : String) : Array(Cap)
      result = remote_exec("getcap -v #{shell_quote(path)}")
      stdout = result[:stdout].strip
      stderr = result[:stderr].strip
      raise CapError.new("Unable to get capabilities of #{path}") if result[:exit_code] != 0 || !stderr.empty?

      return [] of Cap if stdout == path

      caps_str = if stdout.includes?(" =")
                   stdout.split(" =")[1]? || ""
                 elsif stdout.ends_with?(')')
                   raise CapError.new("Unable to get capabilities of #{path}")
                 else
                   stdout.split(' ', 2)[1]? || ""
                 end

      rval = [] of Cap
      caps_str.split.each do |cap|
        cap = cap.downcase
        if cap.includes?(',')
          group = cap.split(',')
          name, op, flags = parse_cap(group.last, op_required: false)
          group[0..-2].each { |subcap| rval << {subcap, op, flags} }
          rval << {name, op, flags}
        else
          rval << parse_cap(cap, op_required: false)
        end
      end
      rval
    end

    private def setcap(path : String, caps : Array(Cap)) : String
      cap_string = caps.map { |(name, op, flags)| "#{name}#{op}#{flags}" }.join(" ")
      result = remote_exec("setcap #{shell_quote(cap_string)} #{shell_quote(path)}")
      raise CapError.new("Unable to set capabilities of #{path}: #{result[:stderr]}") if result[:exit_code] != 0
      result[:stdout]
    end

    private def parse_cap(cap : String, op_required : Bool) : Cap
      op_index = -1
      op_char = ""
      OPS.each do |op|
        idx = cap.index(op)
        next unless idx
        if op_index == -1 || idx < op_index
          op_index = idx
          op_char = op
        end
      end

      if op_index == -1
        raise CapError.new("Couldn't find operator (one of: #{OPS.join(", ")})") if op_required
        return {cap, nil, nil}
      end

      parts = cap.split(op_char, 2)
      {parts[0], op_char, parts[1]?}
    end

    private def shell_quote(s : String) : String
      Process.quote(s)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::CapabilitiesPlugin.new(config)
plugin.run
