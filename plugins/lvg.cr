#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # lvg plugin - creates, extends, shrinks, or removes LVM volume groups
  # via pvcreate/vgcreate/vgextend/vgreduce/vgremove, a native reimplementation of
  # community.general.lvg (companion to this repo's existing
  # lvol/filesystem plugins).
  #
  # Implemented against real lvg.py's control flow:
  #   - discovery via `vgs --noheadings -o vg_name,pv_count,lv_count
  #     --separator ';' <vg>` (Ansible's own -o list, so lv_count is
  #     available for the absent-state refusal)
  #   - on an existing VG: Ansible's PV diff - requested PVs missing from
  #     the VG get pvcreate -f + vgextend; VG PVs not in the request get
  #     `vgreduce --force` (unless remove_extra_pvs=false), with Ansible's
  #     "Unable to extend/reduce ..." fail_json messages
  #   - remove via vgremove --force, but only when the VG holds no
  #     logical volumes or force=true - otherwise Ansible's exact
  #     "Refuse to remove non-empty volume group ..." failure
  #   - check mode: discovery runs for real, mutating commands are not
  #     run (changed verdict still reported)
  #
  # pesize is accepted and forwarded to vgcreate -s (Ansible's default
  # is 4M); pv_options/vg_options are split on whitespace and
  # appended, matching the Ansible module's own shlex-lite handling of
  # them.
  class LvgPlugin < BasePlugin
    # Real lvg.py's state choices (community.general 7.1.0 added
    # active/inactive: "The states V(active) and V(inactive) implies
    # V(present) state"), in declaration order.
    private LVG_STATES = %w[absent present active inactive]

    def execute : PluginResult # ameba:disable Metrics/CyclomaticComplexity
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

      # Real required_if: ["reset_pv_uuid", True, ["pvs"]].
      if true?(@params["reset_pv_uuid"]?) && @params["pvs"]?.nil?
        return PluginResult.new(changed: false, failed: true,
          msg: "reset_pv_uuid is True but all of the following are missing: pvs")
      end

      pvs_param = @params["pvs"]?
      pvs = pvs_param.try { |device| device.split(/[\s,]+/).reject(&.empty?) } || [] of String

      check_mode = true?(@params["_ansible_check_mode"]?)
      force = true?(@params["force"]?)

      # Real main() starts with find_vg() -> get_bin_path("vgs", True),
      # so a host without the LVM2 tools fails with that exact message
      # before any VG discovery happens - the previous behavior ran the
      # vgs probe, treated the failure as "VG does not exist" and
      # marched on into vgcreate.
      unless find_required_binary("vgs")
        return PluginResult.new(changed: false, failed: true,
          msg: missing_executable_message("vgs"))
      end

      # Ansible's "No physical volumes given." fires after find_vg, and
      # only when the VG doesn't exist yet (pvs_required = present-state
      # AND this_vg is None) - a state=present call against an existing
      # VG without pvs is Ansible's grow-to-nothing no-op, not an error.
      discovery = remote_exec("vgs --noheadings -o vg_name,pv_count,lv_count --separator ';' #{Shell.single_quote(vg)} 2>/dev/null")
      vg_exists = false
      lv_count = 0
      if discovery[:exit_code] == 0
        discovery[:stdout].each_line do |line|
          parts = line.strip.split(';')
          next unless parts.size >= 3 && parts[0] == vg
          vg_exists = true
          lv_count = parts[2].to_i? || 0
          break
        end
      end

      if pvs.empty? && !vg_exists && state != "absent"
        return PluginResult.new(changed: false, failed: true,
          msg: "No physical volumes given.")
      end

      # Real checks every requested PV device for existence BEFORE any LVM
      # command runs (lvg.py: os.path.realpath on each entry, then
      # os.path.exists -> "Device {dev} not found."), which is the failure
      # the kop_storage lvg_fail probe captures: Ansible never reaches
      # vgcreate with a nonexistent PV. The resolved (realpath'd) names
      # are what real feeds to every later command and comparison.
      resolved_pvs = [] of String
      if state != "absent"
        pvs.each do |device|
          resolved = remote_exec("readlink -f -- #{Shell.single_quote(device)}")[:stdout].strip
          resolved = device if resolved.empty?
          found = remote_exec("[ -e #{Shell.single_quote(resolved)} ]")
          unless found[:exit_code] == 0
            return PluginResult.new(changed: false, failed: true,
              msg: "Device #{resolved} not found.")
          end
          resolved_pvs << resolved
        end
      end

      if state == "absent"
        return absent_vg(vg, vg_exists, lv_count, force, check_mode)
      end

      present_vg(vg, resolved_pvs, vg_exists, check_mode)
    end

    private LVG_SPEC = {
      "vg"               => [] of String,
      "pvs"              => [] of String,
      "pesize"           => [] of String,
      "pv_options"       => [] of String,
      "pvresize"         => [] of String,
      "vg_options"       => [] of String,
      "state"            => [] of String,
      "force"            => [] of String,
      "reset_vg_uuid"    => [] of String,
      "reset_pv_uuid"    => [] of String,
      "remove_extra_pvs" => [] of String,
    }

    private def absent_vg(vg : String, vg_exists : Bool, lv_count : Int32, force : Bool, check_mode : Bool) : PluginResult
      # Every real lvg exit is `module.exit_json(changed=...)` - the
      # module never passes msg on a success path, so the registered
      # result is [changed, failed] (round 992003 kop_storage lvg_create/
      # lvg_exists captures).
      return PluginResult.new(changed: false, failed: false) unless vg_exists
      return PluginResult.new(changed: true, failed: false) if check_mode

      # Ansible refuses to remove a VG that still holds logical volumes
      # unless force=true (round 993003 cold cleanup: kop_vg still
      # contained kop_lv, so real failed the cleanup task with Ansible's
      # exact refusal message while krikri marched into vgremove and
      # surfaced the interactive-prompt rc/err instead).
      unless lv_count == 0 || force
        return PluginResult.new(changed: false, failed: true,
          msg: "Refuse to remove non-empty volume group #{vg} without force=true")
      end

      # Ansible always passes --force here (its own command list hardcodes
      # it), whether or not the force parameter was set.
      result = remote_exec("vgremove --force #{Shell.single_quote(vg)}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to remove volume group #{vg}",
          rc: result[:exit_code], err: result[:stderr],
          key_order: LVG_FAIL_KEY_ORDER)
      end
      PluginResult.new(changed: true, failed: false)
    end

    # Ansible's fail_json kwargs (rc, err) lead the registered result, then
    # failed/msg/changed/exception (round 992003 lvol_fail capture; same
    # rule for lvg's rc/err-carrying failures).
    private LVG_FAIL_KEY_ORDER = %w[rc err failed msg changed exception]

    private def present_vg(vg : String, pvs : Array(String), vg_exists : Bool, check_mode : Bool) : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      pesize = @params["pesize"]? || "4"
      vg_options = @params["vg_options"]?.try(&.split) || [] of String
      pv_options = @params["pv_options"]?.try(&.split) || [] of String
      remove_extra_pvs = true?(@params["remove_extra_pvs"]?, default: true)

      # Real lvg.py runs the pvs probe for EVERY present-state call
      # (before the VG-exists branch), using it both for the used_pvs
      # gate and - when the VG exists - for the requested-vs-current PV
      # diff that drives vgextend/vgreduce.
      parsed = pv_entries
      return parsed if parsed.is_a?(PluginResult)

      # Ansible's used_pvs gate: a requested PV that already belongs to a
      # DIFFERENT volume group fails before any command runs.
      used = parsed.select { |entry| pvs.includes?(entry[:name]) && !entry[:vg_name].empty? && entry[:vg_name] != vg }
      unless used.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "Device #{used[0][:name]} is already in #{used[0][:vg_name]} volume group.")
      end

      unless vg_exists
        return PluginResult.new(changed: true, failed: false) if check_mode

        # Real creates each PV first (pvcreate -f, honoring pv_options)
        # before vgcreate - the old krikri path skipped pvcreate entirely
        # and relied on vgcreate succeeding anyway.
        pvs.each do |device|
          result = remote_exec("pvcreate #{pv_options.map { |option| Shell.single_quote(option) }.join(' ')} -f #{Shell.single_quote(device)}")
          unless result[:exit_code] == 0
            return PluginResult.new(changed: false, failed: true,
              msg: "Creating physical volume '#{device}' failed",
              rc: result[:exit_code], err: result[:stderr],
              key_order: LVG_FAIL_KEY_ORDER)
          end
        end

        result = remote_exec("vgcreate #{vg_options.map { |option| Shell.single_quote(option) }.join(' ')} -s #{Shell.single_quote(pesize)} #{Shell.single_quote(vg)} #{pvs.map { |device| Shell.single_quote(device) }.join(' ')}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Creating volume group '#{vg}' failed",
            rc: result[:exit_code], err: result[:stderr],
            key_order: LVG_FAIL_KEY_ORDER)
        end
        return PluginResult.new(changed: true, failed: false)
      end

      # Ansible's PV-diff on an existing VG: PVs in the VG but not requested
      # get vgreduce'd (unless remove_extra_pvs=false), requested PVs not
      # in the VG get pvcreate -f + vgextend. Adds run before removes.
      # This is what makes a warm rerun against a stale VG fail exactly
      # like real (round 993003: the leaked VG's old PV reduced ->
      # "still in use", instead of krikri's silent changed:true).
      current_devs = parsed.select { |entry| entry[:vg_name] == vg }.map { |entry| realpath(entry[:name]) }
      devs_to_remove = remove_extra_pvs ? current_devs.reject { |device| pvs.includes?(device) } : [] of String
      devs_to_add = pvs.reject { |device| current_devs.includes?(device) }

      return PluginResult.new(changed: false, failed: false) if devs_to_add.empty? && devs_to_remove.empty?
      return PluginResult.new(changed: true, failed: false) if check_mode

      unless devs_to_add.empty?
        devs_to_add.each do |device|
          result = remote_exec("pvcreate #{pv_options.map { |option| Shell.single_quote(option) }.join(' ')} -f #{Shell.single_quote(device)}")
          unless result[:exit_code] == 0
            return PluginResult.new(changed: false, failed: true,
              msg: "Creating physical volume '#{device}' failed",
              rc: result[:exit_code], err: result[:stderr],
              key_order: LVG_FAIL_KEY_ORDER)
          end
        end

        result = remote_exec("vgextend #{Shell.single_quote(vg)} #{devs_to_add.map { |device| Shell.single_quote(device) }.join(' ')}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Unable to extend #{vg} by #{devs_to_add.join(" ")}.",
            rc: result[:exit_code], err: result[:stderr],
            key_order: LVG_FAIL_KEY_ORDER)
        end
      end

      unless devs_to_remove.empty?
        result = remote_exec("vgreduce --force #{Shell.single_quote(vg)} #{devs_to_remove.map { |device| Shell.single_quote(device) }.join(' ')}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Unable to reduce #{vg} by #{devs_to_remove.join(" ")}.",
            rc: result[:exit_code], err: result[:stderr],
            key_order: LVG_FAIL_KEY_ORDER)
        end
      end

      PluginResult.new(changed: true, failed: false)
    end

    # os.path.realpath via readlink -f, falling back to the input when
    # readlink cannot resolve it (matches the pre-existing device-existence
    # check's handling).
    private def realpath(device : String) : String
      resolved = remote_exec("readlink -f -- #{Shell.single_quote(device)}")[:stdout].strip
      resolved.empty? ? device : resolved
    end

    # Parses `pvs --noheadings -o pv_name,vg_name --separator ';'` into
    # {name, vg_name} entries, or a failed PluginResult when the probe
    # itself fails (real: fail_json "Failed executing pvs command." with
    # the rc/err kwargs).
    private def pv_entries : Array(NamedTuple(name: String, vg_name: String)) | PluginResult
      result = remote_exec("pvs --noheadings -o pv_name,vg_name --separator ';'")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed executing pvs command.",
          rc: result[:exit_code], err: result[:stderr],
          key_order: LVG_FAIL_KEY_ORDER)
      end

      entries = [] of NamedTuple(name: String, vg_name: String)
      result[:stdout].each_line do |line|
        parts = line.strip.split(';')
        next unless parts.size >= 2
        entries << {name: parts[0], vg_name: parts[1]}
      end
      entries
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::LvgPlugin.new(config)
plugin.run
