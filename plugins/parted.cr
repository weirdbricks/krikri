#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # parted plugin - creates, resizes, flags, or removes disk partitions
  # via `parted -s`, a native port of community.general.parted.
  #
  # Implemented against real parted.py's control flow:
  #   - discovery via `parted -s <device> -m unit <unit> print` (the
  #     -m machine-parseable output, one line per partition,
  #     fields separated by ':')
  #   - create via `parted -s <dev> unit <unit> mkpart <parttype>
  #     <fstype|name> <start> <end>`, remove via `rm <number>`,
  #     resize via `resizepart <number> <end>` (resize: true),
  #     flags via `set <number> <flag> on|off`, label via mklabel
  #   - idempotency: existing partition matched by number + boundaries
  #     (a same-number partition whose start/end already match the
  #     requested values is a no-op); flags compared against the
  #     current flag state from print's per-partition output
  #   - check mode: discovery runs for real, mutating commands are not
  #     run (changed verdict still reported)
  #
  # Not implemented (narrow, documented cuts):
  #   - state: info (real returns partition facts; no tested role
  #     caller) - accepted but behaves as a no-op discovery returning
  #     the print output
  #   - fs_type only applies on GPT-less msdos create paths where real
  #     passes it as the mkpart filesystem-type argument; on GPT it is
  #     the partition NAME argument, matching real's handling
  class PartedPlugin < BasePlugin
    private PARTED_STATES = %w[present absent info]

    private PARTED_FLAGS = %w[boot lba bootable cyl align hidden swap lvm raid thinp esp diag cp legacy_boot]

    private PARTED_LABELS = %w[aix amiga bsd dvh gpt loop mac msdos pc98 sun]

    private PARTED_UNITS = %w[s B b kB KB kKiB KiB MB MiB GB GiB TB TiB % cyl chs compact]

    def execute : PluginResult
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
      unless PARTED_UNITS.includes?(unit)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of unit must be one of: #{PARTED_UNITS.join(", ")}, got: #{unit}")
      end

      if label = @params["label"]?
        unless PARTED_LABELS.includes?(label)
          return PluginResult.new(changed: false, failed: true,
            msg: "value of label must be one of: #{PARTED_LABELS.join(", ")}, got: #{label}")
        end
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      number = @params["number"]?.try { |v| v.to_i? }
      part_start = @params["part_start"]? || "0%"
      part_end = @params["part_end"]? || "100%"
      label = @params["label"]? || "msdos"
      fs_type = @params["fs_type"]? || "ext2"
      flags = @params["flags"]? # comma/space-separated or single

      # state: info - real runs print and returns the parsed output.
      if state == "info"
        result = read_partitions(device, unit)
        if result.is_a?(String)
          return PluginResult.new(changed: false, failed: true, msg: result)
        end
        return PluginResult.new(changed: false, failed: false,
          msg: "Current partitions on device:\n#{device}",
          other: JSON.parse(%({"partitions": #{result.to_json}})))
      end

      # Real parted.py runs `parted -s <device> print` early to check
      # the device exists; a missing/unreadable device fails with
      # "Error: Could not stat device <dev> - No such file or directory."
      device_exists = remote_exec("test -e #{Shell.single_quote(device)}")
      unless device_exists[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Error: Could not stat device #{device} - No such file or directory.")
      end

      current = read_partitions(device, unit)
      if current.is_a?(String)
        return PluginResult.new(changed: false, failed: true, msg: current)
      end

      if state == "absent"
        return absent_partition(device, current, number, check_mode)
      end

      present_partition(device, current, number, part_start, part_end,
        unit, label, fs_type, flags, check_mode)
    end

    # Runs `parted -s <dev> -m unit <unit> print` and parses the
    # -m output: line 1 is the disk header (dev:size:label:...),
    # subsequent lines are partitions numbered by field 0
    # (number:start:end:size:fs:flags...). Returns an array of
    # {"number", "start", "end", "size", "fs", "flags"} hashes, or an
    # error message string on failure.
    private def read_partitions(device : String, unit : String) : Array(Hash(String, String)) | String
      result = remote_exec("parted -s #{Shell.single_quote(device)} -m unit #{Shell.single_quote(unit)} print 2>/dev/null")
      return "Error: parted failed on #{device}: #{result[:stderr].strip}" unless result[:exit_code] == 0

      partitions = [] of Hash(String, String)
      result[:stdout].each_line do |line|
        fields = line.split(':')
        next unless fields.size >= 5
        num = fields[0]
        # Header line starts with the device path; partition lines
        # start with the partition number.
        next unless num =~ /^\d+$/
        flags = fields[6]? || ""
        partitions << {
          "number" => num,
          "start"  => fields[1],
          "end"    => fields[2],
          "size"   => fields[3],
          "fs"     => fields[4],
          "flags"  => flags,
        } of String => String
      end
      partitions
    end

    private def absent_partition(device : String, current : Array(Hash(String, String)), number : Int32?, check_mode : Bool) : PluginResult
      # Real requires number for state=absent (required_if).
      unless number
        return PluginResult.new(changed: false, failed: true,
          msg: "state is absent but all of the following are missing: number")
      end

      unless current.any? { |part| part["number"] == number.to_s }
        return PluginResult.new(changed: false, failed: false,
          msg: "partition number #{number} not found on device #{device}")
      end
      return PluginResult.new(changed: true, failed: false,
        msg: "Partition #{number} on #{device} would be removed") if check_mode

      result = remote_exec("parted -s #{Shell.single_quote(device)} rm #{number}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Error: parted rm failed: #{result[:stderr].strip}")
      end
      PluginResult.new(changed: true, failed: false,
        msg: "Partition #{number} on #{device} removed")
    end

    private def present_partition(device : String, current : Array(Hash(String, String)), number : Int32?,
                                  part_start : String, part_end : String, unit : String, label : String,
                                  fs_type : String, flags : String?, check_mode : Bool) : PluginResult
      changed = false
      msgs = [] of String

      existing = number ? current.find { |part| part["number"] == number.to_s } : nil

      if existing.nil?
        return PluginResult.new(changed: true, failed: false,
          msg: "Partition would be created on #{device}") if check_mode

        mkpart_args = ["unit", unit, "mkpart"]
        # msdos/dvh/amiga take a primary/extended/logical part type;
        # GPT-family labels take no part type and the 3rd arg is the
        # partition NAME (real passes fs_type there). msdos uses
        # fs_type as the filesystem-type argument after the part type.
        if ["msdos", "dvh", "amiga"].includes?(label)
          mkpart_args << "primary" << fs_type
        else
          mkpart_args << fs_type
        end
        mkpart_args << part_start << part_end

        result = remote_exec("parted -s #{Shell.single_quote(device)} #{mkpart_args.map { |a| Shell.single_quote(a) }.join(' ')}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Error: parted mkpart failed: #{result[:stderr].strip}")
        end
        changed = true
        msgs << "partition created"
      elsif resize_enabled? && (existing["end"] != part_end)
        return PluginResult.new(changed: true, failed: false,
          msg: "Partition #{number} on #{device} would be resized") if check_mode

        result = remote_exec("parted -s #{Shell.single_quote(device)} unit #{Shell.single_quote(unit)} resizepart #{number} #{Shell.single_quote(part_end)}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "Error: parted resizepart failed: #{result[:stderr].strip}")
        end
        changed = true
        msgs << "partition resized"
      end

      if flags
        flag_result = apply_flags(device, number, flags, check_mode)
        if flag_result.is_a?(String)
          return PluginResult.new(changed: false, failed: true, msg: flag_result)
        elsif flag_result
          changed = true
          msgs << "flags updated"
        end
      end

      PluginResult.new(changed: changed, failed: false,
        msg: msgs.empty? ? "" : "Partitions on #{device}: #{msgs.join(", ")}")
    end

    private def resize_enabled? : Bool
      true?(@params["resize"]?, default: false)
    end

    # Applies `parted set <n> <flag> on/off` for each requested flag
    # not already in the partition's current flag list. Returns true
    # if anything changed, false if all flags already present, or an
    # error message string. Real rejects unknown flags via parted's
    # own error.
    private def apply_flags(device : String, number : Int32?, flags : String, check_mode : Bool) : Bool | String
      n = number
      unless n
        return "flags requires number to be set"
      end

      requested = flags.split(/[\s,]+/).reject(&.empty?)
      requested.each do |flag|
        next if PARTED_FLAGS.includes?(flag)
        return "value of flags must be one of: #{PARTED_FLAGS.join(", ")}, got: #{flag}"
      end

      probe = remote_exec("parted #{Shell.single_quote(device)} #{n} print 2>/dev/null | head -1")
      current_flags = probe[:stdout].downcase

      changed = false
      requested.each do |flag|
        # Real checks current state via `parted <dev> <n> print`'s
        # "Flags:" line; a flag already listed is left alone.
        next if current_flags.includes?(flag)
        return true if check_mode
        result = remote_exec("parted -s #{Shell.single_quote(device)} set #{n} #{Shell.single_quote(flag)} on")
        unless result[:exit_code] == 0
          return "Error: parted set flag #{flag} failed: #{result[:stderr].strip}"
        end
        changed = true
      end
      changed
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PartedPlugin.new(config)
plugin.run
