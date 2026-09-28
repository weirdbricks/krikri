require "../minitest_helper"
require "../../src/krikri/plugin_helpers/docker_healthcheck"

# Duration parsing and test normalization verified against real Ansible's
# own community.docker module_utils source (`convert_duration_to_nanosecond`,
# `normalize_healthcheck_test`, `parse_healthcheck` in
# plugins/module_utils/_util.py) - see plugins/docker_container.cr's own
# doc comment.
describe Krikri::PluginHelpers::DockerHealthcheck do
  include RaisesAssertion
  describe ".duration_to_ns" do
    include RaisesAssertion
    it "parses a plain seconds duration" do
      Krikri::PluginHelpers::DockerHealthcheck.duration_to_ns("10s").must_equal(10_000_000_000_i64)
    end

    it "parses a combined minutes+seconds duration" do
      Krikri::PluginHelpers::DockerHealthcheck.duration_to_ns("1m30s").must_equal(90_000_000_000_i64)
    end

    it "parses a full hours+minutes+seconds duration" do
      Krikri::PluginHelpers::DockerHealthcheck.duration_to_ns("5h34m56s").must_equal(20_096_000_000_000_i64)
    end

    it "parses milliseconds/microseconds" do
      Krikri::PluginHelpers::DockerHealthcheck.duration_to_ns("500ms").must_equal(500_000_000_i64)
      Krikri::PluginHelpers::DockerHealthcheck.duration_to_ns("500us").must_equal(500_000_i64)
    end

    it "raises on an unparseable duration" do
      assert_raises_message(Exception, "Invalid time duration") do
        Krikri::PluginHelpers::DockerHealthcheck.duration_to_ns("not-a-duration")
      end
    end
  end

  describe ".normalize_test" do
    include RaisesAssertion
    it "passes a list test straight through as strings" do
      test = JSON.parse(%(["CMD", "curl", "--fail", "http://localhost"]))
      Krikri::PluginHelpers::DockerHealthcheck.normalize_test(test).must_equal(["CMD", "curl", "--fail", "http://localhost"])
    end

    it "wraps a plain string test as CMD-SHELL (matches real Ansible's normalize_healthcheck_test)" do
      test = JSON.parse(%("curl --fail http://localhost"))
      Krikri::PluginHelpers::DockerHealthcheck.normalize_test(test).must_equal(["CMD-SHELL", "curl --fail http://localhost"])
    end
  end

  describe ".parse" do
    include RaisesAssertion
    it "parses a full healthcheck dict" do
      json = %({"test": ["CMD", "curl", "--fail", "http://localhost"], "interval": "1m30s", "timeout": "10s", "retries": 3, "start_period": "30s"})
      parsed = (Krikri::PluginHelpers::DockerHealthcheck.parse(json) || raise "unexpected nil")
      parsed.test.must_equal(["CMD", "curl", "--fail", "http://localhost"])
      parsed.interval.must_equal(90_000_000_000_i64)
      parsed.timeout.must_equal(10_000_000_000_i64)
      parsed.retries.must_equal(3_i64)
      parsed.start_period.must_equal(30_000_000_000_i64)
    end

    it "passes through test: [NONE] as the real, documented way to disable an inherited healthcheck" do
      parsed = (Krikri::PluginHelpers::DockerHealthcheck.parse(%({"test": ["NONE"]})) || raise "unexpected nil")
      parsed.test.must_equal(["NONE"])
    end

    it "returns nil when test: is missing entirely (matches real Ansible's parse_healthcheck - no override at all)" do
      Krikri::PluginHelpers::DockerHealthcheck.parse(%({"interval": "30s"})).must_be_nil
    end
  end
end
