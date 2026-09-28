require "../minitest_helper"
require "../../src/krikri/plugin_helpers/docker_resources"

# Byte-size parsing verified against real Ansible's own `human_to_bytes`
# (`ansible/module_utils/common/text/formatters.py`'s `SIZE_RANGES`) -
# binary (1024-based) units despite the non-"i" K/M/G/T/P spelling.
describe Krikri::PluginHelpers::DockerResources do
  include RaisesAssertion
  describe ".human_to_bytes" do
    include RaisesAssertion
    it "parses a bare number with no unit as already-bytes" do
      Krikri::PluginHelpers::DockerResources.human_to_bytes("1024").must_equal(1024_i64)
    end

    it "parses M/G/K suffixes as binary (1024-based) units" do
      Krikri::PluginHelpers::DockerResources.human_to_bytes("1K").must_equal(1024_i64)
      Krikri::PluginHelpers::DockerResources.human_to_bytes("512M").must_equal(512_i64 * 1024 * 1024)
      Krikri::PluginHelpers::DockerResources.human_to_bytes("1G").must_equal(1024_i64 * 1024 * 1024)
    end

    it "only looks at the first letter of the unit (MB and M are equivalent)" do
      Krikri::PluginHelpers::DockerResources.human_to_bytes("1MB").must_equal(1024_i64 * 1024)
    end

    it "handles a decimal number with a unit" do
      Krikri::PluginHelpers::DockerResources.human_to_bytes("1.5G").must_equal((1.5 * 1024 * 1024 * 1024).round.to_i64)
    end

    it "raises on an unparseable string" do
      assert_raises_message(Exception, "can't interpret") do
        Krikri::PluginHelpers::DockerResources.human_to_bytes("not-a-size")
      end
    end

    it "raises on an unrecognized unit suffix" do
      assert_raises_message(Exception, "must be one of") do
        Krikri::PluginHelpers::DockerResources.human_to_bytes("5X")
      end
    end
  end

  describe ".memory_swap_to_bytes" do
    include RaisesAssertion
    it "converts 'unlimited' and '-1' to the literal -1 (real Ansible's own unlimited-swap convention)" do
      Krikri::PluginHelpers::DockerResources.memory_swap_to_bytes("unlimited").must_equal(-1_i64)
      Krikri::PluginHelpers::DockerResources.memory_swap_to_bytes("-1").must_equal(-1_i64)
    end

    it "otherwise parses like any other byte-size value" do
      Krikri::PluginHelpers::DockerResources.memory_swap_to_bytes("1G").must_equal(1024_i64 * 1024 * 1024)
    end
  end

  describe ".cpus_to_nano_cpus" do
    include RaisesAssertion
    it "converts a float CPU count to nanocpus (cpus * 1e9)" do
      Krikri::PluginHelpers::DockerResources.cpus_to_nano_cpus(1.5).must_equal(1_500_000_000_i64)
    end

    it "rounds fractional nanocpus" do
      Krikri::PluginHelpers::DockerResources.cpus_to_nano_cpus(0.1).must_equal(100_000_000_i64)
    end
  end
end
