#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/lvol_size"

module Krikri
  # lvol plugin - creates, resizes, (de)activates or removes LVM logical
  # volumes, a native port of community.general.lvol (ansible-core's
  # ansible.builtin.lvol is the same module - it only ever lived in one
  # place, historically under ansible-core then community.general; this
  # repo registers one binary under both FQCNs, same shape as the
  # mysql_db/mariadb_db dual-namespace registrations).
  #
  # Implemented against real lvol.py's own main() (community.general,
  # read from a live collection install), following its control flow
  # command for command:
  #   - vgs/lvs discovery of the VG and LV state (same -o field lists,
  #     same --separator ";" parsing)
  #   - create via lvcreate, resize via lvextend/lvreduce (+ --resizefs),
  #     remove via lvremove (force: true required), (de)activate via
  #     lvchange -ay/-an
  #   - size grammar [+-]N[unit] and [+-]N%VG|PVS|FREE|ORIGIN, including
  #     the real module's round-down-to-extent and "more than an extent
  #     too large" shrink semantics
  #   - thin pools (-T), thin volumes (-V onto an existing pool) and
  #     snapshots (-s -n)
  #   - check mode: discovery runs for real, mutating commands are not
  #     run (real module's --test no-ops, with the same changed verdict)
  #
  # Deliberately out of scope (both mirror a real-module precondition
  # this environment can't satisfy, not a corner cut):
  #   - gss-tsig-style oddities: none - but the `lvm version >= 2.2.99`
  #     probe for --yes is skipped: every LVM2 release since 2012 has it,
  #     so --yes is always passed (real module would otherwise only pass
  #     it on modern LVM)
  #   - `opts:` is split on whitespace rather than full shlex (real
  #     roles pass flags like "--type cache-pool" / "-r 16"; quoted
  #     opt values are not supported)
  class LvolPlugin < BasePlugin
    def execute : PluginResult
      vg = @params["vg"]?
      return missing_required("vg") unless vg

      lv = @params["lv"]?
      thinpool = @params["thinpool"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "one of the following is required: lv, thinpool") unless lv || thinpool

      check_mode = true?(@params["check_mode"]?)
      state = @params["state"]? || "present"
      return PluginResult.new(changed: false, failed: true,
        msg: "state must be 'present' or 'absent', got '#{state}'") unless ["present", "absent"].includes?(state)

      parsed_size, size_error = PluginHelpers::LvolSize.parse(@params["size"]?)
      return failed(size_error.not_nil!) if size_error

      snapshot = @params["snapshot"]?
      if (whole = parsed_size.try(&.whole)) && whole == "ORIGIN" && snapshot.nil?
        return failed("Percentage of ORIGIN supported only for snapshot volumes")
      end

      opts = (@params["opts"]? || "").split
      pvs = parse_pvs
      force = true?(@params["force"]?)
      shrink = true?(@params["shrink"]?, default: true)
      active = true?(@params["active"]?, default: true)
      resizefs = true?(@params["resizefs"]?)

      vgs_result = remote_exec(vgs_command(vg, parsed_size.try(&.units_flag) || "m"))
      return absent_vg_result(vg, state) if vgs_result[:exit_code] != 0
      this_vg = parse_vgs(vgs_result[:stdout])
      return failed("Volume group #{vg} does not exist.") if this_vg.empty?
      vg_info = this_vg.first

      lvs_result = remote_exec(lvs_command(vg, parsed_size.try(&.units_flag) || "m"))
      return absent_vg_result(vg, state) if lvs_result[:exit_code] != 0
      lvs = parse_lvs(lvs_result[:stdout])

      # check_lv mirrors real module: the name looked up in lvs output
      check_lv = if snapshot
                   origin = lvs.find { |test| test[:name] == lv || test[:name] == thinpool }
                   if origin.nil?
                     return failed("Snapshot origin LV #{lv} does not exist in volume group #{vg}.")
                   elsif !origin[:thinpool] && thinpool.nil?
                     # plain origin - fine
                   else
                     return failed("Snapshots of thin pool LVs are not supported.")
                   end
                   snapshot
                 elsif thinpool && lv
                   unless lvs.any? { |test| test[:name] == thinpool }
                     return failed("Thin pool LV #{thinpool} does not exist in volume group #{vg}.")
                   end
                   lv
                 else
                   (lv || thinpool).not_nil!
                 end

      this_lv = lvs.find { |test| test[:name] == check_lv || test[:name] == check_lv.split('/')[-1] }

      changed = false
      msg = ""

      if this_lv.nil?
        if state == "present"
          if (op = parsed_size.try(&.operator)) &&
             (op == "-" || !["VG", "PVS", "FREE", "ORIGIN", nil].includes?(parsed_size.try(&.whole)))
            return failed("Bad size specification of '#{op}#{parsed_size.not_nil!.value}' for creating LV")
          end
          unless parsed_size
            # Real module: size required when creating, except a snapshot
            # of a thin volume - which this port does not support either.
            return failed("No size given.")
          end

          return PluginResult.new(changed: true, failed: false,
            msg: "Would create #{lv || thinpool}") if check_mode

          if thinpool && lv && parsed_size.not_nil!.opt == "l"
            return failed("Thin volume sizing with percentage not supported.")
          end

          cmd = build_create_command(vg, lv, thinpool, snapshot, parsed_size.not_nil!, opts, pvs)
          create_result = remote_exec(cmd)
          return failed("Creating logical volume '#{lv}' failed: #{create_result[:stderr]}") if create_result[:exit_code] != 0

          changed = true
        end
      elsif state == "absent"
        return failed("Sorry, no removal of logical volume #{this_lv[:name]} without force=true.") unless force

        return PluginResult.new(changed: true, failed: false,
          msg: "Would remove #{this_lv[:name]}") if check_mode

        remove_result = remote_exec("lvremove --force #{shell_quote("#{vg}/#{this_lv[:name]}")}")
        return failed("Failed to remove logical volume #{lv}: #{remove_result[:stderr]}") if remove_result[:exit_code] != 0

        return PluginResult.new(changed: true, failed: false, msg: "")
      elsif !parsed_size
        # no size change requested; fall through to activation handling
      else
        resized = resize(this_vg.first, this_lv, lv, parsed_size.not_nil!, opts, pvs,
          force, shrink, resizefs, check_mode)
        return failed(resized[:msg] || "resize failed") if resized[:failed]
        changed = true if resized[:changed_flag]
        msg = resized[:msg] || ""
      end

      if this_lv && !check_mode
        lvchange_flag = active ? "-ay" : "-an"
        change_result = remote_exec("lvchange #{lvchange_flag} #{shell_quote("#{vg}/#{this_lv[:name]}")}")
        return failed("Failed to #{active ? "activate" : "deactivate"} logical volume #{lv}: #{change_result[:stderr]}") if change_result[:exit_code] != 0

        changed = ((this_lv[:active] != active) || changed)
      elsif this_lv
        changed = ((this_lv[:active] != active) || changed)
      end

      PluginResult.new(changed: changed, failed: false, msg: msg, vg: vg, lv: lv || thinpool)
    end

    # The two resize branches of real main() (percent-based and
    # absolute-based), collapsed: both compute the requested size, pick
    # lvextend or lvreduce, and append the same command tail. Returns a
    # named tuple {changed_flag, failed, msg}.
    private def resize(
      vg_info : NamedTuple(name: String, size: Float64, free: Float64, ext_size: Float64),
      this_lv : NamedTuple(name: String, size: Float64, active: Bool, thinpool: Bool, thinvol: Bool),
      lv : String?, parsed : PluginHelpers::LvolSize::Parsed,
      opts : Array(String), pvs : Array(String),
      force : Bool, shrink : Bool, resizefs : Bool, check_mode : Bool,
    )
      lv_path = "#{vg_info[:name]}/#{this_lv[:name]}"

      if parsed.opt == "l"
        size_percent = parsed.percent.not_nil!
        size_requested = if parsed.whole == "VG" || parsed.whole == "PVS"
                           size_percent * vg_info[:size] / 100
                         else
                           size_percent * vg_info[:free] / 100
                         end
        case parsed.operator
        when "+"
          size_requested += this_lv[:size]
        when "-"
          size_requested = this_lv[:size] - size_requested
        end
        # all LVM tools round down to whole extents
        size_requested -= size_requested % vg_info[:ext_size]

        if this_lv[:size] < size_requested
          size_free = vg_info[:free]
          if size_free <= 0 || size_free < (size_requested - this_lv[:size])
            return {changed_flag: false, failed: true,
              msg: "Logical Volume #{this_lv[:name]} could not be extended. Not enough free space left " \
                   "(#{size_requested - this_lv[:size]}m required / #{size_free}m available)"}
          end
          return resize_run("lvextend", size_requested, parsed, lv_path, opts, pvs, resizefs, check_mode, false)
        elsif shrink && this_lv[:size] > size_requested + vg_info[:ext_size]
          return {changed_flag: false, failed: true,
            msg: "Sorry, no shrinking of #{this_lv[:name]} to 0 permitted."} if size_requested < 1
          return {changed_flag: false, failed: true,
            msg: "Sorry, no shrinking of #{this_lv[:name]} without force=true"} unless force
          return resize_run("lvreduce --force", size_requested, parsed, lv_path, opts, pvs, resizefs, check_mode, true)
        end
      else
        size_val = parsed.value.to_f64
        if size_val > this_lv[:size] || parsed.operator == "+"
          return resize_run("lvextend", size_val, parsed, lv_path, opts, pvs, resizefs, check_mode, false)
        elsif shrink && (size_val < this_lv[:size] || parsed.operator == "-")
          return {changed_flag: false, failed: true,
            msg: "Sorry, no shrinking of #{this_lv[:name]} to 0 permitted."} if size_val == 0
          return {changed_flag: false, failed: true,
            msg: "Sorry, no shrinking of #{this_lv[:name]} without force=true."} unless force
          return resize_run("lvreduce --force", size_val, parsed, lv_path, opts, pvs, resizefs, check_mode, true)
        end
      end

      {changed_flag: false, failed: false, msg: ""}
    end

    private def resize_run(
      tool : String, size_requested : Float64, parsed : PluginHelpers::LvolSize::Parsed,
      lv_path : String, opts : Array(String), pvs : Array(String),
      resizefs : Bool, check_mode : Bool, shrinking : Bool,
    )
      return {changed_flag: true, failed: false, msg: "Would resize #{lv_path}"} if check_mode

      resizefs_flag = resizefs ? " --resizefs" : ""
      operator = parsed.operator ? parsed.operator : ""
      cmd = "#{tool}#{resizefs_flag} -#{parsed.opt} #{operator}#{parsed.value}#{parsed.value_unit} " \
            "#{opts.join(' ')} #{shell_quote(lv_path)} #{pvs.join(' ')}".split(' ', remove_empty: true).join(' ')
      result = remote_exec(cmd)
      if result[:exit_code] != 0
        # Real module's own convergent-no-op exits: lvm sometimes refuses
        # with these messages when the request lands on the current size
        # (common with --resizefs) - reported as changed: false, not a
        # failure.
        out = result[:stdout]
        err = result[:stderr]
        if out.includes?("matches existing size") || err.includes?("matches existing size")
          return {changed_flag: false, failed: false, msg: ""}
        elsif out.includes?("not larger than existing size") || err.includes?("not larger than existing size")
          return {changed_flag: false, failed: false, msg: "Original size is larger than requested size"}
        end
        return {changed_flag: false, failed: true,
          msg: "Unable to resize #{lv_path}: #{err}"}
      end

      {changed_flag: true, failed: false, msg: "Volume #{lv_path} resized"}
    end

    private def build_create_command(
      vg : String, lv : String?, thinpool : String?, snapshot : String?,
      parsed : PluginHelpers::LvolSize::Parsed, opts : Array(String), pvs : Array(String),
    ) : String
      cmd = ["lvcreate", "--yes"]
      if snapshot
        cmd << "-#{parsed.opt} #{parsed.value}#{parsed.value_unit}"
        cmd << "-s"
        cmd << "-n #{snapshot}"
      elsif thinpool && lv
        cmd << "-n #{lv}"
        cmd << "-V #{parsed.value}#{parsed.value_unit}"
        cmd << "-T #{shell_quote("#{vg}/#{thinpool}")}"
        return cmd.concat(opts).concat(pvs).join(' ')
      elsif thinpool
        cmd << "-#{parsed.opt} #{parsed.value}#{parsed.value_unit}"
        cmd << "-T #{shell_quote("#{vg}/#{thinpool}")}"
        return cmd.concat(opts).concat(pvs).join(' ')
      else
        cmd << "-n #{lv}"
        cmd << "-#{parsed.opt} #{parsed.value}#{parsed.value_unit}"
      end
      cmd.concat(opts)
      cmd << shell_quote(vg)
      cmd.concat(pvs)
      cmd.join(' ')
    end

    private def vgs_command(vg : String, units : String) : String
      "vgs --noheadings --nosuffix -o vg_name,size,free,vg_extent_size " \
        "--units #{units.downcase} --separator ';' #{shell_quote(vg)}"
    end

    private def lvs_command(vg : String, units : String) : String
      "lvs -a --noheadings --nosuffix -o lv_name,size,lv_attr " \
        "--units #{units.downcase} --separator ';' #{shell_quote(vg)}"
    end

    private def parse_vgs(data : String)
      data.split('\n').compact_map do |line|
        parts = line.strip.split(';')
        next nil if parts.size < 4
        {name: parts[0], size: parts[1].to_f? || 0.0,
         free: parts[2].to_f? || 0.0, ext_size: parts[3].to_f? || 0.0}
      end
    end

    private def parse_lvs(data : String)
      data.split('\n').compact_map do |line|
        parts = line.strip.split(';')
        next nil if parts.size < 3
        attr = parts[2]
        {name: parts[0].delete("[]"), size: parts[1].to_f? || 0.0,
         active: attr.size > 4 && attr[4] == 'a',
         thinpool: attr.size > 0 && attr[0] == 't',
         thinvol: attr.size > 0 && attr[0] == 'V'}
      end
    end

    private def parse_pvs : Array(String)
      raw = @params["pvs"]?
      return [] of String unless raw
      values = if raw.lstrip.starts_with?('[')
                 JSON.parse(raw).as_a.map(&.as_s)
               else
                 raw.split(',').map(&.strip).reject(&.empty?)
               end
      values.map { |dev| shell_quote(dev) }
    rescue JSON::ParseException
      [] of String
    end

    private def absent_vg_result(vg : String, state : String) : PluginResult
      if state == "absent"
        PluginResult.new(changed: false, failed: false, msg: "Volume group #{vg} does not exist.")
      else
        failed("Volume group #{vg} does not exist.")
      end
    end

    private def missing_required(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "missing required argument: #{name}")
    end

    private def failed(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    private def shell_quote(s : String) : String
      "'" + s.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::LvolPlugin.new(config)
plugin.run
