#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/lvol_size"

module Krikri
  # lvol plugin - creates, resizes, (de)activates or removes LVM logical
  # volumes, a native reimplementation of community.general.lvol (ansible-core's
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
    include PluginHelpers::AnsibleArgValidation

    # Real lvol.py's own argument_spec (community.general, declaration
    # order) - drives the module-setup validation below exactly the way
    # real AnsibleModule does.
    private LVOL_SPEC = {
      "vg"       => [] of String,
      "lv"       => [] of String,
      "size"     => [] of String,
      "opts"     => [] of String,
      "state"    => [] of String,
      "force"    => [] of String,
      "shrink"   => [] of String,
      "active"   => [] of String,
      "snapshot" => [] of String,
      "pvs"      => [] of String,
      "resizefs" => [] of String,
      "thinpool" => [] of String,
    }

    private LVOL_BOOL_PARAMS = %w[force shrink active resizefs]

    private LVOL_STATES = %w[absent present]

    def execute : PluginResult
      # Real AnsibleModule setup validation, in real order: unsupported
      # params first (message wording live-verified via the podman-diff
      # lvol_edge_cases LV3 case: "Unsupported parameters for
      # (community.general.lvol) module: X. Supported parameters
      # include: ..."), then required (LV1: "missing required
      # arguments: vg" - the previous hand-rolled singular
      # "missing required argument: vg" was never real), then
      # required_one_of (LV2), then state choices (LV5: real's choice
      # list is [absent, present] - active/inactive are NOT real
      # choices) and bool-typed params (LV4).
      unsupported = unsupported_param_keys(@params, LVOL_SPEC)
      unless unsupported.empty?
        return unsupported_params_error(
          @params["_module_name"]? || "community.general.lvol",
          unsupported, LVOL_SPEC,
        )
      end

      vg = @params["vg"]?
      return missing_required_error(["vg"]) unless vg

      lv = @params["lv"]?
      thinpool = @params["thinpool"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "one of the following is required: lv, thinpool") unless lv || thinpool

      state = @params["state"]? || "present"
      unless LVOL_STATES.includes?(state)
        return choices_error("state", LVOL_STATES, state)
      end

      LVOL_BOOL_PARAMS.each do |bool_param|
        next unless (raw = @params[bool_param]?)
        unless bool_convertible?(raw)
          return bool_type_error(bool_param, raw)
        end
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      state = @params["state"]? || "present"

      # Real main() starts with get_lvm_version() ->
      # get_bin_path("lvm", required=True) - so a host without the LVM2
      # tools fails with that exact message before the size grammar,
      # the VG discovery, or anything else module-level runs. This
      # plugin previously parsed/validated size and probed the VG first
      # and reported its own downstream failures ("Bad size
      # specification of 'X'", "Volume group X does not exist.") on
      # hosts where real stops at the executable lookup.
      unless find_required_binary("lvm")
        return PluginResult.new(changed: false, failed: true,
          msg: missing_executable_message("lvm"))
      end

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
      return absent_vg_result(vg, state, vgs_result) if vgs_result[:exit_code] != 0
      this_vg = parse_vgs(vgs_result[:stdout])
      return failed("Volume group #{vg} does not exist.") if this_vg.empty?

      lvs_result = remote_exec(lvs_command(vg, parsed_size.try(&.units_flag) || "m"))
      return absent_vg_result(vg, state, lvs_result) if lvs_result[:exit_code] != 0
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

          # Real's check-mode create runs `lvcreate --test` and falls
          # through to the final exit_json(changed=changed, msg=msg)
          # with the (empty) msg variable - the registered shape is
          # [changed, msg, failed] with msg "", not a "Would create"
          # invention (round 992003 lvol_create capture).
          return PluginResult.new(changed: true, failed: false, msg: "",
            include_empty_msg: true, key_order: %w[changed msg]) if check_mode

          if thinpool && lv && parsed_size.not_nil!.opt == "l"
            return failed("Thin volume sizing with percentage not supported.")
          end

          cmd = build_create_command(vg, lv, thinpool, snapshot, parsed_size.not_nil!, opts, pvs)
          create_result = remote_exec(cmd)
          if create_result[:exit_code] != 0
            return PluginResult.new(changed: false, failed: true,
              msg: "Creating logical volume '#{lv}' failed",
              rc: create_result[:exit_code], err: create_result[:stderr],
              key_order: %w[rc err failed msg changed exception])
          end

          changed = true
        end
      elsif state == "absent"
        return failed("Sorry, no removal of logical volume #{this_lv[:name]} without force=true.") unless force

        # Real's check-mode removal runs `lvremove --test` and exits
        # exit_json(changed=True) - no msg key (lvol.py's absent branch).
        return PluginResult.new(changed: true, failed: false,
          key_order: %w[changed]) if check_mode

        remove_result = remote_exec("lvremove --force #{shell_quote("#{vg}/#{this_lv[:name]}")}")
        if remove_result[:exit_code] != 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to remove logical volume #{lv}",
            rc: remove_result[:exit_code], err: remove_result[:stderr],
            key_order: %w[rc err failed msg changed exception])
        end

        return PluginResult.new(changed: true, failed: false, key_order: %w[changed])
      elsif !parsed_size
        # no size change requested; fall through to activation handling
      else
        resized = resize(this_vg.first, this_lv, lv, parsed_size.not_nil!, opts, pvs,
          force, shrink, resizefs, check_mode)
        # Real's resize failure carries the rc/err run_command kwargs,
        # which lead the registered result ahead of failed/msg
        # (round 992003 lvol_fail: [rc, err, failed, msg, changed,
        # exception], msg "Unable to resize kop_lv to 1G").
        if resized[:failed]
          if (rc = resized[:rc])
            return PluginResult.new(changed: false, failed: true,
              msg: resized[:msg],
              rc: rc, err: resized[:err],
              key_order: resized[:out] ? %w[rc err out failed msg changed exception] : %w[rc err failed msg changed exception])
          end
          return failed(resized[:msg])
        end
        case resized[:early]
        when :matches
          # Real's convergent no-op exit: exit_json(changed=False,
          # vg=vg, lv=this_lv["name"], size=this_lv["size"]) - no msg.
          return PluginResult.new(changed: false, failed: false,
            vg: vg, lv: this_lv[:name], size: this_lv[:size],
            key_order: LVOL_LV_KEY_ORDER)
        when :not_larger
          return PluginResult.new(changed: false, failed: false,
            vg: vg, lv: this_lv[:name], size: this_lv[:size],
            msg: "Original size is larger than requested size",
            err: resized[:err],
            key_order: %w[changed vg lv size msg err])
        end
        changed = true if resized[:changed_flag]
      end

      if this_lv && !check_mode
        lvchange_flag = active ? "-ay" : "-an"
        change_result = remote_exec("lvchange #{lvchange_flag} #{shell_quote("#{vg}/#{this_lv[:name]}")}")
        if change_result[:exit_code] != 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to #{active ? "activate" : "deactivate"} logical volume #{lv}",
            rc: change_result[:exit_code], err: change_result[:stderr],
            key_order: %w[rc err failed msg changed exception])
        end
        changed = ((this_lv[:active] != active) || changed)
      elsif this_lv
        changed = ((this_lv[:active] != active) || changed)
      end

      if this_lv
        # Real's this_lv-exists exit (lvol.py's lvchange section, both
        # the active and inactive branches):
        # exit_json(changed=..., vg=vg, lv=this_lv["name"],
        # size=this_lv["size"]) - no msg key at all, not even in check
        # mode (round 992003 lvol_exists/lvol_check captures), and
        # size is the CURRENT LV size as a JSON float (64.0).
        PluginResult.new(changed: changed, failed: false,
          vg: vg, lv: this_lv[:name], size: this_lv[:size],
          key_order: LVOL_LV_KEY_ORDER)
      else
        # Real's create-path exit is the final
        # exit_json(changed=changed, msg=msg) with the empty msg
        # variable passed explicitly - the key exists even when empty
        # (round 992003 lvol_create), and carries no vg/lv/size.
        PluginResult.new(changed: changed, failed: false, msg: "",
          include_empty_msg: true, key_order: %w[changed msg])
      end
    end

    # The registered key order for every lvol exit that reaches the
    # lvchange tail with this_lv present.
    private LVOL_LV_KEY_ORDER = %w[changed vg lv size]

    # The two resize branches of real main() (percent-based and
    # absolute-based), collapsed: both compute the requested size, pick
    # lvextend or lvreduce, and append the same command tail. Returns a
    # named tuple {changed_flag, failed, msg, rc, err, out, early} -
    # rc/err/out carry real's fail_json kwargs on a command failure and
    # early marks real's early exit_json branches (:matches,
    # Observed behavior: not_larger) that bypass the lvchange tail.
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
                         "(#{size_requested - this_lv[:size]}m required / #{size_free}m available)",
                    rc: nil, err: nil, out: nil, early: nil}
          end
          return resize_run(lv, "lvextend", size_requested, parsed, lv_path, opts, pvs, resizefs, check_mode, false)
        elsif shrink && this_lv[:size] > size_requested + vg_info[:ext_size]
          return {changed_flag: false, failed: true,
                  msg: "Sorry, no shrinking of #{this_lv[:name]} to 0 permitted.",
                  rc: nil, err: nil, out: nil, early: nil} if size_requested < 1
          return {changed_flag: false, failed: true,
                  msg: "Sorry, no shrinking of #{this_lv[:name]} without force=true",
                  rc: nil, err: nil, out: nil, early: nil} unless force
          return resize_run(lv, "lvreduce --force", size_requested, parsed, lv_path, opts, pvs, resizefs, check_mode, true)
        end
      else
        size_val = parsed.value.to_f64
        if size_val > this_lv[:size] || parsed.operator == "+"
          return resize_run(lv, "lvextend", size_val, parsed, lv_path, opts, pvs, resizefs, check_mode, false)
        elsif shrink && (size_val < this_lv[:size] || parsed.operator == "-")
          return {changed_flag: false, failed: true,
                  msg: "Sorry, no shrinking of #{this_lv[:name]} to 0 permitted.",
                  rc: nil, err: nil, out: nil, early: nil} if size_val == 0
          return {changed_flag: false, failed: true,
                  msg: "Sorry, no shrinking of #{this_lv[:name]} without force=true.",
                  rc: nil, err: nil, out: nil, early: nil} unless force
          return resize_run(lv, "lvreduce --force", size_val, parsed, lv_path, opts, pvs, resizefs, check_mode, true)
        end
      end

      {changed_flag: false, failed: false, msg: "", rc: nil, err: nil, out: nil, early: nil}
    end

    private def resize_run(
      lv_param : String?, tool : String, size_requested : Float64, parsed : PluginHelpers::LvolSize::Parsed,
      lv_path : String, opts : Array(String), pvs : Array(String),
      resizefs : Bool, check_mode : Bool, shrinking : Bool,
    )
      return {changed_flag: true, failed: false, msg: "Would resize #{lv_path}",
              rc: nil, err: nil, out: nil, early: nil} if check_mode

      resizefs_flag = resizefs ? " --resizefs" : ""
      operator = parsed.operator ? parsed.operator : ""
      cmd = "#{tool}#{resizefs_flag} -#{parsed.opt} #{operator}#{parsed.value}#{parsed.value_unit} " \
            "#{opts.join(' ')} #{shell_quote(lv_path)} #{pvs.join(' ')}".split(' ', remove_empty: true).join(' ')
      result = remote_exec(cmd)
      out = result[:stdout]
      err = result[:stderr]
      # Real's own failure wording: fail_json(msg="Unable to resize {lv}
      # to {size}{unit}", rc=rc, err=err) - the param lv name, the
      # requested size WITHOUT the operator, and the raw stderr as err
      # (round 992003 lvol_fail). The COW branch adds the out kwarg.
      unable = "Unable to resize #{lv_param || lv_path.split('/')[-1]} to #{parsed.value}#{parsed.value_unit}"
      if out.includes?("Reached maximum COW size")
        return {changed_flag: false, failed: true, msg: unable,
                rc: result[:exit_code], err: err, out: out, early: nil}
      elsif result[:exit_code] != 0
        # Real module's own convergent-no-op exits: lvm sometimes refuses
        # with these messages when the request lands on the current size
        # (common with --resizefs) - reported as changed: false, not a
        # failure.
        if out.includes?("matches existing size") || err.includes?("matches existing size")
          return {changed_flag: false, failed: false, msg: "",
                  rc: nil, err: nil, out: nil, early: :matches}
        elsif out.includes?("not larger than existing size") || err.includes?("not larger than existing size")
          return {changed_flag: false, failed: false, msg: "Original size is larger than requested size",
                  rc: result[:exit_code], err: err, out: nil, early: :not_larger}
        end
        return {changed_flag: false, failed: true, msg: unable,
                rc: result[:exit_code], err: err, out: nil, early: nil}
      end

      {changed_flag: true, failed: false, msg: "Volume #{lv_path} resized",
       rc: nil, err: nil, out: nil, early: nil}
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

    private def absent_vg_result(vg : String, state : String, probe : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      if state == "absent"
        # Real module: state=absent against a missing VG exits ok with
        # changed=false and NO msg (live-verified via the podman-diff
        # lvol_edge_cases LV7 case - the "Volume group ... does not
        # exist." msg was this engine's own invention there).
        PluginResult.new(changed: false, failed: false)
      else
        # Real's present-state failure carries the vgs run_command
        # result as rc/err kwargs, which lead the registered result
        # (lvol.py: fail_json(msg=..., rc=rc, err=err)).
        PluginResult.new(changed: false, failed: true,
          msg: "Volume group #{vg} does not exist.",
          rc: probe[:exit_code], err: probe[:stderr],
          key_order: %w[rc err failed msg changed exception])
      end
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
