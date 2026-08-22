require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/service_facts_parser"

private alias ServiceFactsParser = CrystalPlay::PluginHelpers::ServiceFactsParser

describe ServiceFactsParser do
  describe ".parse_active_states" do
    it "parses a running service correctly despite leading row indentation" do
      # Real bug found benchmarking linux-system-roles.network (round
      # 160): `systemctl list-units --no-legend` still indents every
      # row with leading whitespace. Splitting on /\s+/ without
      # stripping first produces a leading empty-string element,
      # shifting every column one field early - the service name
      # landed under the "" key, and the SUB column check ("running")
      # actually compared against the ACTIVE column instead, so
      # `state` came back "stopped" for every service regardless of
      # its real state.
      output = "  NetworkManager.service                    loaded    active   running Network Manager\n"
      result = ServiceFactsParser.parse_active_states(output)
      result["NetworkManager.service"]?.should eq("running")
      result[""]?.should be_nil
    end

    it "reports a loaded-but-inactive service as stopped" do
      output = "  sshd.service                                loaded    inactive dead    OpenSSH server\n"
      result = ServiceFactsParser.parse_active_states(output)
      result["sshd.service"]?.should eq("stopped")
    end
  end

  describe ".parse_unit_files" do
    it "parses unit file state correctly despite leading row indentation" do
      output = "  sshd.service                               enabled         enabled\n"
      result = ServiceFactsParser.parse_unit_files(output)
      result["sshd.service"]?.should eq("enabled")
    end
  end
end
