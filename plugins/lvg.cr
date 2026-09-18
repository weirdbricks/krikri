#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # lvg plugin - creates, extends, or removes LVM volume groups via
  # vgcreate/vgextend/vgremove, a native port of community.general.lvg
  # (companion to this repo's existing lvol/filesystem plugins).
  #
  # Implemented against real lvg.py's control flow:
  #   - discovery via `vgs --noheadings -o vg_name,pv_count,vg_size
  #     --separator ; <vg>` (same -o list real uses)
  #   - create via vgcreate (or vgextend when the VG exists but a
  #     requested PV is missing from it - real's grow-only semantics;
  #     shrinking is not supported by the real module either)
  #   - remove via vgremove -f (force required, same as real)
  #   - check mode: discovery runs for real, mutating commands are not
  #     run (changed verdict still reported)
  #
  # pesize is accepted and forwarded to vgcreate -s (real's default
  # is 4M); pv_options/vg_options are split on whitespace and
  # appended, matching the real module's own shlex-lite handling of
  # them.
  class LvgPlugin < BasePlugin
    private LVG_STATES = %w[present absent]

    def execute : PluginResult
      unsupported = @params.keys.reject { |k| k.starts_with?("_") || LVG_SPEC.has_key?(k) }
      unless unsupported.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "Unsupported parameters for (community.general.lvg) module: #{unsupported.sort.join(", ")}. Supported parameters include: #{LVG_SPEC.keys.join(", ")}.")
      end

      vg = @params["vg"]?
      unless vg
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: vg")
      end

      state = @params["state"]? || "present"
      unless LVG_STATES.includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: #{LVG_STATES.join(", ")}, got: #{state}")
      end

      pvs_param = @params["pvs"]?
      pvs = pvs_param.try { |device| device.split(/[\s,]+/).reject(&.empty?) } || [] of String
      if state == "present" && pvs.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is present but all of the following are missing: pvs")
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      force = true?(@params["force"]?)

      discovery = remote_exec("vgs --noheadings -o vg_name,pv_count,vg_size --separator ';' #{Shell.single_quote(vg)} 2>/dev/null")
      vg_exists = discovery[:exit_code] == 0 && !discovery[:stdout].strip.empty?

      if state == "absent"
        return absent_vg(vg, vg_exists, force, check_mode)
      end

      present_vg(vg, pvs, vg_exists, check_mode)
    end

    private LVG_SPEC = {
      "vg"         => [] of String,
      "pvs"        => [] of String,
      "pesize"     => [] of String,
      "pv_options" => [] of String,
      "vg_options" => [] of String,
      "state"      => [] of String,
      "force"      => [] of String,
    }

    private def absent_vg(vg : String, vg_exists : Bool, force : Bool, check_mode : Bool) : PluginResult
      return PluginResult.new(changed: false, failed: false, msg: "") unless vg_exists
      return PluginResult.new(changed: true, failed: false,
        msg: "Volume group #{vg} would be removed") if check_mode

      result = remote_exec("vgremove #{force ? "-f" : ""} #{Shell.single_quote(vg)}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to remove volume group #{vg}: #{result[:stderr].strip}")
      end
      PluginResult.new(changed: true, failed: false,
        msg: "Volume group #{vg} removed")
    end

    private def present_vg(vg : String, pvs : Array(String), vg_exists : Bool, check_mode : Bool) : PluginResult
      pesize = @params["pesize"]? || "4"
      vg_options = @params["vg_options"]?.try(&.split) || [] of String

      # Which of the requested PVs are already part of the VG (if it
      # exists) - real lvg.py parses `pvs --noheadings -o
      # pv_name,vg_name` for this. Missing PVs in an existing VG mean
      # a vgextend; a nonexistent VG means vgcreate with all PVs.
      if vg_exists
        missing = missing_pvs(vg, pvs)
        return PluginResult.new(changed: false, failed: true, msg: missing) if missing.is_a?(String)

        if missing.empty?
          return PluginResult.new(changed: false, failed: false,
            msg: "Volume group #{vg} already exists")
        end
        return PluginResult.new(changed: true, failed: false,
          msg: "Volume group #{vg} would be extended") if check_mode

        result = remote_exec("vgextend #{vg_options.map { |option| Shell.single_quote(option) }.join(' ')} #{Shell.single_quote(vg)} #{missing.map { |device| Shell.single_quote(device) }.join(' ')}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to extend volume group #{vg}: #{result[:stderr].strip}")
        end
        return PluginResult.new(changed: true, failed: false,
          msg: "Volume group #{vg} extended")
      end

      return PluginResult.new(changed: true, failed: false,
        msg: "Volume group #{vg} would be created") if check_mode

      result = remote_exec("vgcreate -s #{Shell.single_quote(pesize)} #{vg_options.map { |option| Shell.single_quote(option) }.join(' ')} #{Shell.single_quote(vg)} #{pvs.map { |device| Shell.single_quote(device) }.join(' ')}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to create volume group #{vg}: #{result[:stderr].strip}")
      end
      PluginResult.new(changed: true, failed: false,
        msg: "Volume group #{vg} created")
    end

    # Returns the requested PVs not currently in the VG, or an error
    # message string when the pvs probe itself fails.
    private def missing_pvs(vg : String, pvs : Array(String)) : Array(String) | String
      result = remote_exec("pvs --noheadings -o pv_name,vg_name 2>/dev/null")
      return "Failed to query existing PVs: #{result[:stderr].strip}" unless result[:exit_code] == 0

      in_vg = Set(String).new
      result[:stdout].each_line do |line|
        fields = line.split
        next unless fields.size >= 2
        in_vg << fields[0] if fields[1] == vg
      end
      pvs.reject { |device| in_vg.includes?(device) }
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::LvgPlugin.new(config)
plugin.run
