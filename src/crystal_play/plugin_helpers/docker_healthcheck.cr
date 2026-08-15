module CrystalPlay
  module PluginHelpers
    # DockerHealthcheck - pure logic for parsing a docker_container
    # `healthcheck:` param into Docker's own `HealthConfig` shape. No I/O
    # here - docker_container.cr does the actual API calls.
    module DockerHealthcheck
      record Parsed, test : Array(String)?, interval : Int64?, timeout : Int64?, retries : Int64?, start_period : Int64?

      # Matches real Ansible's own `convert_duration_to_nanosecond`
      # exactly (same regex, same unit set: h/m/s/ms/us - no day unit).
      # Raises with the real module's own error message shape for an
      # unparseable string.
      def self.duration_to_ns(str : String) : Int64
        m = str.match(/\A(?:(?<hours>\d+)h)?(?:(?<minutes>\d+)m(?!s))?(?:(?<seconds>\d+)s)?(?:(?<milliseconds>\d+)ms)?(?:(?<microseconds>\d+)us)?\z/)
        raise "Invalid time duration - #{str}" unless m

        hours = m["hours"]?.try(&.to_i64) || 0_i64
        minutes = m["minutes"]?.try(&.to_i64) || 0_i64
        seconds = m["seconds"]?.try(&.to_i64) || 0_i64
        millis = m["milliseconds"]?.try(&.to_i64) || 0_i64
        micros = m["microseconds"]?.try(&.to_i64) || 0_i64

        (hours*3600 + minutes*60 + seconds) * 1_000_000_000_i64 + millis*1_000_000_i64 + micros*1_000_i64
      end

      # Matches real Ansible's own `normalize_healthcheck_test`: a plain
      # string (not a JSON array) becomes a CMD-SHELL invocation of that
      # string, matching real Docker CLI/Ansible convention.
      def self.normalize_test(test : JSON::Any) : Array(String)
        return test.as_a.map(&.as_s) if test.raw.is_a?(Array)
        ["CMD-SHELL", test.as_s]
      end

      # Returns nil if `healthcheck:` was given but has no `test:` (or an
      # empty one) - matches real Ansible's own `parse_healthcheck`: with
      # no test, there's nothing to override, and the image's own
      # healthcheck (if any) is left alone entirely, same as not passing
      # `healthcheck:` at all. `test: ["NONE"]` is the real, documented
      # way to explicitly disable an inherited healthcheck - passed
      # through as-is (Docker's own convention for "no healthcheck").
      def self.parse(json : String) : Parsed?
        parsed = JSON.parse(json)
        test = parsed["test"]?
        return nil unless test

        normalized_test = normalize_test(test)
        return nil if normalized_test.empty?

        Parsed.new(
          test: normalized_test,
          interval: parsed["interval"]?.try { |v| duration_to_ns(v.as_s) },
          timeout: parsed["timeout"]?.try { |v| duration_to_ns(v.as_s) },
          retries: parsed["retries"]?.try(&.as_i64),
          start_period: parsed["start_period"]?.try { |v| duration_to_ns(v.as_s) },
        )
      end
    end
  end
end
