#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # parted plugin - creates, resizes, flags, or removes disk partitions
  # via `parted -s`, a native reimplementation of community.general.parted.
  #
  # Implemented against real parted.py's control flow, including its
  # result shapes (round 992003 kop_storage captures):
  #   - every exit is `exit_json(changed=..., disk=..., partitions=...,
  #     script=...)` - disk is the parsed "generic" block (dev, size,
  #     unit, table, model, logical_block, physical_block), partitions
  #     the parsed print rows (num, begin, end, size, fstype, name,
  #     flags, unit), script the exact parted script list that ran (or
  #     would have run in check mode)
  #   - a device WITHOUT a disk label is not an error: get_device_info
  #     runs `parted -s -m <dev> -- unit <unit> print`, and when it
  #     exits non-zero with "unrecognised disk label" the stdout is
  #     parsed anyway (parted still prints the BYT;/disk line with
  #     table "unknown") - the missing label then drives mklabel in the
  #     script. Only a non-label failure (e.g. a nonexistent device)
  #     fails with Ansible's rc/out/err-carrying shape
  #   - the script is built exactly like real: mklabel when the current
  #     table differs, mkpart (with the part_type, and fs_type ONLY when
  #     the user passed one - there is no ext2 default) when the label
  #     changes or the partition is missing, resizepart/name/set
  #     additions, "unit <unit>" prefixed onto each actual run
  #   - script runs go through `parted [-s|-s -f] -m -a <align> <dev>
  #     -- <script>`; -f only on parted >= 3.4.64 (probed via
  #     `parted --version`, like real)
  #   - check mode: discovery runs for real, script runs are skipped
  #     (changed verdict still reported, script still reported)
  class PartedPlugin < BasePlugin
    # Ansible's argument_spec's deterministic orders (live-verified wording
    # against 2.19.11: "value of state must be one of: absent, info,
    # present, got: X"; "value of unit must be one of: B, KB, MB, GB, TB,
    # KiB, MiB, GiB, TiB, s, %, cyl, chs, compact, got: X" - Ansible's
    # units_si + units_iec + ["s", "%", "cyl", "chs", "compact"]; it
    # accepts neither the bare "b" nor "kB"/"kKiB").
    private PARTED_STATES = %w[absent info present]

    private PARTED_UNITS_ORDER = %w[B KB MB GB TB KiB MiB GiB TiB s % cyl chs compact]

    private PARTED_LABELS = %w[aix amiga bsd dvh gpt loop mac msdos pc98 sun]

    private PARTED_PART_TYPES = %w[extended logical primary]

    private PARTED_ALIGNS = %w[cylinder minimal none optimal undefined]

    private UNITS_SI = %w[B KB MB GB TB]

    private UNITS_IEC = %w[KiB MiB GiB TiB]

    # Ansible's fail_json kwargs (rc, out, err) lead the registered result,
    # then failed/msg/changed/exception (round 992003 parted_fail:
    # [rc, out, err, failed, msg, changed, exception]).
    private PARTED_FAIL_KEY_ORDER = %w[rc out err failed msg changed exception]

    # The single success exit: exit_json(changed=changed, disk=...,
    # partitions=..., script=...) plus the controller's failed backfill.
    private PARTED_KEY_ORDER = %w[changed disk partitions script]

    @parted_version : Tuple(Int32, Int32, Int32)? = nil

    def execute : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      device = @params["device"]?
      unless device
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: device")
      end

      state = @params["state"]? || "present"
      unless PARTED_STATES.includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: #{PARTED_STATES.join(", ")}, got: #{state}")
      end

      unit = @params["unit"]? || "KiB"
      if error = validate_module_choices(unit)
        return error
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      number, part_start, part_end, label, fs_type, flags, part_type, name, align = resolve_partition_params

      # Ansible's required_if: state=absent needs number (AnsibleModule
      # init-time, before the binary lookup).
      if state == "absent" && number.nil?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is absent but all of the following are missing: number")
      end

      # Real parted.py resolves the parted binary at main() start
      # (get_bin_path("parted", True)) - AFTER the AnsibleModule init
      # validations above, but BEFORE the state:info branch, the device
      # stat, and everything else. A host without parted fails the task
      # with that exact message no matter what state was requested.
      parted_path = find_required_binary("parted")
      unless parted_path
        return PluginResult.new(changed: false, failed: true,
          msg: missing_executable_message("parted"))
      end

      # Ansible's conditioning block: a number below 1 fails before any
      # device access.
      if n = number
        if n < 1
          return PluginResult.new(changed: false, failed: true,
            msg: "The partition number must be greater then 0.")
        end
      end

      # Read the current disk information (this is where Ansible runs
      # `parted --version` for the first time, via check_parted_label).
      current = read_device_info(device, unit, parted_path)
      return current if current.is_a?(PluginResult)

      changed = false
      output_script = [] of String
      script = [] of String
      current_parts = current[:partitions]
      generic = current[:generic]

      case state
      when "present"
        # Assign label if required
        current_table = generic["table"]?.try(&.as_s?)
        mklabel_needed = current_table != label
        if mklabel_needed
          script << "mklabel" << label
        end

        # Create partition if required
        if !part_type.empty? && (mklabel_needed || !part_exists?(current_parts, number))
          script << "mkpart" << part_type
          script << fs_type if fs_type
          script << part_start << part_end
        end

        # Set the unit of the run
        script = ["unit", unit] + script unless script.empty?

        # If partition exists, try to resize
        if resize_enabled? && part_exists?(current_parts, number)
          partition = current_parts.find! { |part| part["num"] == number }
          current_part_end = convert_to_bytes(partition["end"].as_f, unit)

          size, parsed_unit = parse_unit(part_end, unit)
          if parsed_unit == "%"
            size = (generic["size"].as_f * size / 100)
            parsed_unit = unit
          end

          desired_part_end = convert_to_bytes(size, parsed_unit)

          if current_part_end != desired_part_end
            script << "resizepart" << number.not_nil!.to_s << part_end # ameba:disable Lint/NotNil
          end
        end

        # Execute the script and update the data structure.
        if !script.empty?
          output_script += script
          if failure = run_parted_script(script, device, align, parted_path)
            return failure
          end
          changed = true
          script = [] of String

          unless check_mode
            refreshed = read_device_info(device, unit, parted_path)
            return refreshed if refreshed.is_a?(PluginResult)
            current_parts = refreshed[:partitions]
          end
        end

        if part_exists?(current_parts, number) || check_mode
          # check mode with a would-be change has no printed partition
          # row yet - real substitutes an empty flags-only structure
          partition = if changed && check_mode
                        {"flags" => JSON::Any.new([] of JSON::Any)} of String => JSON::Any
                      else
                        current_parts.find { |part| part["num"] == number }
                      end

          if n = number
            # Assign name to the partition
            if (nm = name) && partition && partition["name"]?.try(&.as_s?) != nm
              # The double quotes need to be included in the arg passed
              # to parted (Ansible passes the quoted name verbatim).
              script << "name" << n.to_s << "\"#{nm}\""
            end

            # Manage flags
            if flags
              # Parted infers boot with esp: assigning esp sets boot.
              requested = flags.dup
              if requested.includes?("esp") && !requested.includes?("boot")
                requested << "boot"
              end

              current_flags = partition ? partition["flags"].as_a.map(&.as_s) : [] of String
              # Compute only the changes in flags status (Ansible's
              # set-difference loops, in deterministic order here).
              (requested - current_flags).each do |flag|
                script << "set" << n.to_s << flag << "on"
              end
              (current_flags - requested).each do |flag|
                script << "set" << n.to_s << flag << "off"
              end
            end
          end
        end

        # Set the unit of the run
        script = ["unit", unit] + script unless script.empty?

        # Execute the script
        if !script.empty?
          output_script += script
          if failure = run_parted_script(script, device, align, parted_path)
            return failure
          end
          changed = true
        end
      when "absent"
        # Remove the partition
        if part_exists?(current_parts, number) || check_mode
          script = ["rm", number.not_nil!.to_s] # ameba:disable Lint/NotNil
          output_script += script
          if failure = run_parted_script(script, device, align, parted_path)
            return failure
          end
          changed = true
        end
      when "info"
        output_script = ["unit", unit, "print"]
      end

      # Final status of the device (Ansible runs this unconditionally, check
      # mode included)
      final = read_device_info(device, unit, parted_path)
      return final if final.is_a?(PluginResult)

      result = PluginResult.new(changed: changed, failed: false)
      result.extra["disk"] = JSON::Any.new(final[:generic])
      result.extra["partitions"] = JSON::Any.new(final[:partitions].map { |part| JSON::Any.new(part) })
      result.extra["script"] = JSON::Any.new(output_script.map { |entry| JSON::Any.new(entry) })
      result.key_order = PARTED_KEY_ORDER
      result
    end

    private def resolve_partition_params : {Int32?, String, String, String, String?, Array(String)?, String, String?, String}
      number = @params["number"]?.try { |v| v.to_i? }
      part_start = @params["part_start"]? || "0%"
      part_end = @params["part_end"]? || "100%"
      label = @params["label"]? || "msdos"
      fs_type = @params["fs_type"]?.try { |v| v.empty? ? nil : v }
      flags = parse_flags
      part_type = @params["part_type"]? || "primary"
      name = @params["name"]?.try { |v| v.empty? ? nil : v }
      align = @params["align"]? || "optimal"
      {number, part_start, part_end, label, fs_type, flags, part_type, name, align}
    end

    # AnsibleModule's init-time choices validation, in its own
    # declaration order (device required, then state/unit/label/
    # part_type/align choices).
    private def validate_module_choices(unit : String) : PluginResult?
      unless PARTED_UNITS_ORDER.includes?(unit)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of unit must be one of: #{PARTED_UNITS_ORDER.join(", ")}, got: #{unit}")
      end

      if label = @params["label"]?
        unless PARTED_LABELS.includes?(label)
          return PluginResult.new(changed: false, failed: true,
            msg: "value of label must be one of: #{PARTED_LABELS.join(", ")}, got: #{label}")
        end
      end

      if part_type = @params["part_type"]?
        unless PARTED_PART_TYPES.includes?(part_type)
          return PluginResult.new(changed: false, failed: true,
            msg: "value of part_type must be one of: #{PARTED_PART_TYPES.join(", ")}, got: #{part_type}")
        end
      end

      if align = @params["align"]?
        unless PARTED_ALIGNS.includes?(align)
          return PluginResult.new(changed: false, failed: true,
            msg: "value of align must be one of: #{PARTED_ALIGNS.join(", ")}, got: #{align}")
        end
      end
      nil
    end

    private def parse_flags : Array(String)?
      raw = @params["flags"]?
      return nil unless raw
      begin
        if raw.lstrip.starts_with?('[')
          JSON.parse(raw).as_a.map(&.as_s)
        else
          raw.split(/[\s,]+/).reject(&.empty?)
        end
      rescue JSON::ParseException
        raw.split(/[\s,]+/).reject(&.empty?)
      end
    end

    # Real get_device_info: `parted -s -m <device> -- unit <unit> print`.
    # A non-zero exit that complains about an unrecognised disk label is
    # NOT fatal - parted still printed the BYT;/disk header with table
    # "unknown", which is parsed (this is the loop-device state the
    # kop_storage parted_create probe starts from; the previous port
    # turned it into a task failure Ansible never produces). Any other
    # failure fails with Ansible's exact wrapper message plus rc/out/err.
    private def read_device_info(device : String, unit : String, parted_path : String) : {generic: Hash(String, JSON::Any), partitions: Array(Hash(String, JSON::Any))} | PluginResult
      argv = [parted_path, "-s", "-m", device, "--", "unit", unit, "print"]
      result = remote_exec(argv.map { |arg| Shell.single_quote(arg) }.join(' '))
      if result[:exit_code] != 0 && !result[:stderr].includes?("unrecognised disk label")
        return PluginResult.new(changed: false, failed: true,
          msg: "Error while getting device information with parted script: '#{argv.join(' ')}'",
          rc: result[:exit_code], out: result[:stdout], err: result[:stderr],
          key_order: PARTED_FAIL_KEY_ORDER)
      end

      parse_partition_info(result[:stdout], unit)
    end

    # Mirrors real parse_partition_info: line 1 is the disk header
    # (dev:size:transport:logical:physical:table:model), the remaining
    # lines are partitions (num:begin:end:size:fs:name:flags).
    private def parse_partition_info(parted_output : String, unit : String) : {generic: Hash(String, JSON::Any), partitions: Array(Hash(String, JSON::Any))} | PluginResult # ameba:disable Metrics/CyclomaticComplexity
      lines = parted_output.split('\n').reject { |line| line.strip.empty? }
      if lines.size < 2
        # parted produced nothing parseable; Ansible would crash here -
        # degrade to the get_device_info failure shape instead.
        return PluginResult.new(changed: false, failed: true,
          msg: "Error while getting device information with parted script: (unparseable parted output)",
          key_order: PARTED_FAIL_KEY_ORDER)
      end

      generic_params = lines[1].rstrip(';').split(':')
      size, parsed_unit = parse_unit(generic_params[1], unit)

      generic = {
        "dev"            => JSON::Any.new(generic_params[0]),
        "size"           => JSON::Any.new(size),
        "unit"           => JSON::Any.new(parsed_unit.downcase),
        "table"          => JSON::Any.new(generic_params[5]? || ""),
        "model"          => JSON::Any.new(generic_params[6]? || ""),
        "logical_block"  => JSON::Any.new((generic_params[3]? || "0").to_i64? || 0i64),
        "physical_block" => JSON::Any.new((generic_params[4]? || "0").to_i64? || 0i64),
      } of String => JSON::Any

      # CYL and CHS have an additional line in the output
      if parsed_unit.in?("cyl", "chs")
        chs_info = lines[2].rstrip(';').split(':')
        cyl_size, cyl_unit = parse_unit(chs_info[3])
        generic["chs_info"] = JSON::Any.new({
          "cylinders"     => JSON::Any.new((chs_info[0]? || "0").to_i64? || 0i64),
          "heads"         => JSON::Any.new((chs_info[1]? || "0").to_i64? || 0i64),
          "sectors"       => JSON::Any.new((chs_info[2]? || "0").to_i64? || 0i64),
          "cyl_size"      => JSON::Any.new(cyl_size),
          "cyl_size_unit" => JSON::Any.new(cyl_unit.downcase),
        })
        lines = lines[1..]
      end

      parts = [] of Hash(String, JSON::Any)
      lines[2..].each do |line|
        part_params = line.rstrip(';').split(':')

        if parsed_unit != "chs"
          part_size, _ = parse_unit(part_params[3]? || "0")
          fstype = part_params[4]? || ""
          name = part_params[5]? || ""
          flags = part_params[6]? || ""
          size_json = JSON::Any.new(part_size)
        else
          # Ansible emits the empty string (not a number) for the size of a
          # CHS-parsed partition row
          fstype = part_params[3]? || ""
          name = part_params[4]? || ""
          flags = part_params[5]? || ""
          size_json = JSON::Any.new("")
        end

        parts << {
          "num"    => JSON::Any.new((part_params[0]? || "0").to_i64? || 0i64),
          "begin"  => JSON::Any.new(parse_unit(part_params[1]? || "0")[0]),
          "end"    => JSON::Any.new(parse_unit(part_params[2]? || "0")[0]),
          "size"   => size_json,
          "fstype" => JSON::Any.new(fstype),
          "name"   => JSON::Any.new(name),
          "flags"  => JSON::Any.new(flags.split(", ").reject(&.empty?).map { |flag| JSON::Any.new(flag.strip) }),
          "unit"   => JSON::Any.new(parsed_unit.downcase),
        } of String => JSON::Any
      end

      {generic: generic, partitions: parts}
    end

    # Real parse_unit: "[-]<number>[<unit>]", the CHS triple aside (not
    # needed for -m BYT output). Returns the numeric size and the unit
    # string ("" when the value carried none - the caller's default unit
    # is NOT substituted here for partition rows, matching real, whose
    # parse_unit leaves unit untouched when the value has no suffix).
    private def parse_unit(size_str : String, unit : String = "") : {Float64, String}
      if matches = size_str.strip.match(/^(-?[\d.]+) *([\w%]+)?$/)
        unit = matches[2] if matches[2]
        size = matches[1].to_f64? || 0.0
        return {size, unit}
      end
      {0.0, unit}
    end

    # Real convert_to_bytes: a bare number in *unit* to bytes.
    private def convert_to_bytes(size : Float64, unit : String) : Int64
      multiplier = 1i64
      if UNITS_SI.includes?(unit)
        multiplier = 1000i64 ** (UNITS_SI.index!(unit) + 1)
      elsif UNITS_IEC.includes?(unit)
        multiplier = 1024i64 ** (UNITS_IEC.index!(unit) + 1)
      elsif unit.in?("", "compact", "cyl", "chs")
        multiplier = 1000i64 ** (UNITS_SI.index!("MB") + 1)
      end
      (size * multiplier).to_i64
    end

    private def part_exists?(partitions : Array(Hash(String, JSON::Any)), number : Int32?) : Bool
      return false unless number
      partitions.any? { |part| part["num"].as_i64? == number.to_i64 }
    end

    private def resize_enabled? : Bool
      true?(@params["resize"]?, default: false)
    end

    # Real parted_version(): `parted --version`, parsed once per run.
    # Fails with Ansible's exact message shapes when the binary cannot be
    # run or the version cannot be parsed.
    private def parted_version(parted_path : String) : Tuple(Int32, Int32, Int32) | PluginResult
      if cached = @parted_version
        return cached
      end

      result = remote_exec("#{Shell.single_quote(parted_path)} --version")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to get parted version.",
          rc: result[:exit_code], out: result[:stdout], err: result[:stderr],
          key_order: PARTED_FAIL_KEY_ORDER)
      end

      first_line = result[:stdout].split('\n').first? || ""
      if matches = first_line.match(/^parted.+\s(\d+)\.(\d+)(?:\.(\d+))?/)
        major = matches[1].to_i
        minor = matches[2].to_i
        rev = matches[3]?.try(&.to_i) || 0
        version = {major, minor, rev}
        @parted_version = version
        version
      else
        PluginResult.new(changed: false, failed: true,
          msg: "Failed to get parted version.",
          rc: 0, out: result[:stdout],
          key_order: PARTED_FAIL_KEY_ORDER)
      end
    end

    # Real parted(): builds the actual command line and runs it unless in
    # check mode. The script option is "-s -f" on parted >= 3.4.64 (the
    # --fix flag), plain "-s" before that.
    private def run_parted_script(script : Array(String), device : String, align : String, parted_path : String) : PluginResult?
      check_mode = true?(@params["_ansible_check_mode"]?)
      return nil if check_mode

      version = parted_version(parted_path)
      return version if version.is_a?(PluginResult)
      major, minor, rev = version
      script_option = (major > 3 || (major == 3 && (minor > 4 || (minor == 4 && rev >= 64)))) ? "-s -f" : "-s"
      align_option = align == "undefined" ? "" : "-a #{align}"

      argv = [parted_path] + script_option.split + ["-m"] +
             (align_option.empty? ? [] of String : align_option.split) +
             [device, "--"] + script
      result = remote_exec(argv.map { |arg| Shell.single_quote(arg) }.join(' '))
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Error while running parted script: #{argv.join(' ').strip}",
          rc: result[:exit_code], out: result[:stdout], err: result[:stderr],
          key_order: PARTED_FAIL_KEY_ORDER)
      end
      nil
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PartedPlugin.new(config)
plugin.run
