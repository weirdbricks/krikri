require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/docker_resources"

# Byte-size parsing verified against real Ansible's own `human_to_bytes`
# (`ansible/module_utils/common/text/formatters.py`'s `SIZE_RANGES`) -
# binary (1024-based) units despite the non-"i" K/M/G/T/P spelling.
describe CrystalPlay::PluginHelpers::DockerResources do
  describe ".human_to_bytes" do
    it "parses a bare number with no unit as already-bytes" do
      CrystalPlay::PluginHelpers::DockerResources.human_to_bytes("1024").should eq(1024_i64)
    end

    it "parses M/G/K suffixes as binary (1024-based) units" do
      CrystalPlay::PluginHelpers::DockerResources.human_to_bytes("1K").should eq(1024_i64)
      CrystalPlay::PluginHelpers::DockerResources.human_to_bytes("512M").should eq(512_i64 * 1024 * 1024)
      CrystalPlay::PluginHelpers::DockerResources.human_to_bytes("1G").should eq(1024_i64 * 1024 * 1024)
    end

    it "only looks at the first letter of the unit (MB and M are equivalent)" do
      CrystalPlay::PluginHelpers::DockerResources.human_to_bytes("1MB").should eq(1024_i64 * 1024)
    end

    it "handles a decimal number with a unit" do
      CrystalPlay::PluginHelpers::DockerResources.human_to_bytes("1.5G").should eq((1.5 * 1024 * 1024 * 1024).round.to_i64)
    end

    it "raises on an unparseable string" do
      expect_raises(Exception, "can't interpret") do
        CrystalPlay::PluginHelpers::DockerResources.human_to_bytes("not-a-size")
      end
    end

    it "raises on an unrecognized unit suffix" do
      expect_raises(Exception, "must be one of") do
        CrystalPlay::PluginHelpers::DockerResources.human_to_bytes("5X")
      end
    end
  end

  describe ".memory_swap_to_bytes" do
    it "converts 'unlimited' and '-1' to the literal -1 (real Ansible's own unlimited-swap convention)" do
      CrystalPlay::PluginHelpers::DockerResources.memory_swap_to_bytes("unlimited").should eq(-1_i64)
      CrystalPlay::PluginHelpers::DockerResources.memory_swap_to_bytes("-1").should eq(-1_i64)
    end

    it "otherwise parses like any other byte-size value" do
      CrystalPlay::PluginHelpers::DockerResources.memory_swap_to_bytes("1G").should eq(1024_i64 * 1024 * 1024)
    end
  end

  describe ".cpus_to_nano_cpus" do
    it "converts a float CPU count to nanocpus (cpus * 1e9)" do
      CrystalPlay::PluginHelpers::DockerResources.cpus_to_nano_cpus(1.5).should eq(1_500_000_000_i64)
    end

    it "rounds fractional nanocpus" do
      CrystalPlay::PluginHelpers::DockerResources.cpus_to_nano_cpus(0.1).should eq(100_000_000_i64)
    end
  end
end
