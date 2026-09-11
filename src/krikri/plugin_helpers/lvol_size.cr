module Krikri
  module PluginHelpers
    # LvolSize - parses community.general.lvol's `size:` parameter into
    # the pieces the lvcreate/lvextend/lvreduce command lines need,
    # mirroring real lvol.py's own parsing loop (the section between
    # `if size:` and the `Bad size specification` fail_json).
    #
    # Kept as a pure, side-effect-free helper so the whole grammar can be
    # unit-tested without an LVM stack (the plugin itself shells out to
    # vgs/lvs, which need real volume groups to exercise).
    #
    # Grammar (lvcreate(8)/lvextend(8)/lvreduce(8) -L/-l):
    #   [+-]N[bBsSkKmMgGtTpPeE]   absolute size, default unit MiB
    #   [+-]N%VG|PVS|FREE|ORIGIN  extents as a percentage
    # The +/- operator only applies when resizing (an existing LV);
    # lvcreate itself never takes it.
    module LvolSize
      PERCENT_TARGETS    = ["VG", "PVS", "FREE", "ORIGIN"]
      UNIT_SUFFIXES      = "bskmgtpe"
      DEFAULT_SIZE_UNIT  = "m"
      DEFAULT_EXTENT_UNIT = "m"

      record Parsed,
        # "+", "-" or nil - the resize direction prefix
        operator : String?,
        # the N of N%WHOLE, nil for absolute sizes
        percent : Int32?,
        # "VG"/"PVS"/"FREE"/"ORIGIN", nil for absolute sizes
        whole : String?,
        # the bare numeric string (operator and unit stripped)
        value : String,
        # "L" (absolute/`--size`) or "l" (extents/`--extents`)
        opt : String,
        # unit letter appended to the -L/-l value: "" for extents, the
        # (possibly implicit) unit letter otherwise
        value_unit : String,
        # the --units flag value vgs/lvs are queried with: real module's
        # `unit` variable - always "m" for extents, else value_unit
        units_flag : String

      # Returns {Parsed, nil} on success or {nil, error_message} - the
      # exact error strings real lvol.py's fail_json calls produce.
      def self.parse(size : String?) : {Parsed?, String?}
        return {nil, nil} if size.nil? || size.empty?

        operator = nil
        rest = size
        if rest.starts_with?('+')
          operator = "+"
          rest = rest[1..]
        elsif rest.starts_with?('-')
          operator = "-"
          rest = rest[1..]
        end

        percent = nil
        whole = nil
        opt = "L"
        unit = DEFAULT_SIZE_UNIT

        if rest.includes?('%')
          size_parts = rest.split('%', 2)
          percent = size_parts[0].to_i?
          return {nil, "Bad size specification of '#{size}'"} unless percent
          return {nil, "Size percentage cannot be larger than 100%"} if percent > 100

          whole = size_parts[1]
          if whole == "ORIGIN"
            # ORIGIN's snapshot requirement is checked by the plugin (it
            # needs the snapshot param), not by the parser.
          elsif !PERCENT_TARGETS.includes?(whole)
            return {nil, "Specify extents as a percentage of VG|PVS|FREE|ORIGIN"}
          end
          opt = "l"
          unit = ""
        else
          if !rest.empty? && UNIT_SUFFIXES.includes?(rest[-1].downcase)
            unit = rest[-1].to_s
            rest = rest[0..-2]
          end

          # Real module: float(size) must succeed AND the first char must
          # be a digit (so ".5" is rejected even though Python's float()
          # would parse it; "1e3" IS accepted - first char is a digit and
          # float() handles the exponent).
          if rest.empty? || !rest[0].ascii_number? || rest.to_f?.nil?
            return {nil, "Bad size specification of '#{size}'"}
          end
        end

        {Parsed.new(operator, percent, whole, rest, opt, unit, opt == "l" ? DEFAULT_EXTENT_UNIT : unit), nil}
      end
    end
  end
end
