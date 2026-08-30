module Krikri
  module PluginHelpers
    # DockerResources - pure logic for parsing docker_container's
    # memory/cpu resource-limit params. No I/O here - docker_container.cr
    # does the actual API calls.
    module DockerResources
      # Binary (1024-based) size suffixes, matching real Ansible's own
      # `human_to_bytes` (`SIZE_RANGES` in
      # `ansible/module_utils/common/text/formatters.py`) - K/M/G/T/P are
      # KiB/MiB/GiB/TiB/PiB despite the non-"i" spelling, not decimal
      # 1000-based units.
      SIZE_RANGES = {
        "P" => 1_i64 << 50,
        "T" => 1_i64 << 40,
        "G" => 1_i64 << 30,
        "M" => 1_i64 << 20,
        "K" => 1_i64 << 10,
        "B" => 1_i64,
      }

      # Matches real Ansible's own `human_to_bytes`: a bare number with
      # no unit suffix is returned as-is (already bytes); a number
      # followed by a unit letter (only the first letter matters - "MB"/
      # "M" are equivalent, matching the real function's own
      # `unit[0].upper()`) is converted. Raises with the real function's
      # own error message shape on anything unparseable.
      def self.human_to_bytes(value : String) : Int64
        m = value.strip.match(/\A([0-9]*\.?[0-9]+)(?:\s*([A-Za-z]+))?\z/)
        raise "human_to_bytes() can't interpret following string: #{value}" unless m

        num = m[1].to_f
        unit = m[2]?
        return num.round.to_i64 unless unit

        range_key = unit[0].upcase.to_s
        limit = SIZE_RANGES[range_key]?
        raise "human_to_bytes() failed to convert #{value} (unit = #{unit}). The suffix must be one of #{SIZE_RANGES.keys.join(", ")}" unless limit

        (num * limit).round.to_i64
      end

      # `memory_swap:` alone among the byte-size params also accepts the
      # literal strings `"unlimited"`/`"-1"` for unlimited swap (real
      # Ansible's own documented convention, matching
      # `_preprocess_convert_to_bytes(..., unlimited_value=-1)`).
      def self.memory_swap_to_bytes(value : String) : Int64
        return -1_i64 if value == "unlimited" || value == "-1"
        human_to_bytes(value)
      end

      # Matches real Ansible's own `_preprocess_cpus`: `cpus:` is a
      # float number of CPUs, converted to Docker's own `NanoCpus`
      # (nanocpus = cpus * 1e9, rounded).
      def self.cpus_to_nano_cpus(cpus : Float64) : Int64
        (cpus * 1e9).round.to_i64
      end
    end
  end
end
