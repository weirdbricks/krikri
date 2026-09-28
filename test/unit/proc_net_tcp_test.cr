require "../minitest_helper"
require "../../src/krikri/plugin_helpers/proc_net_tcp"

# Real /proc/net/tcp content captured from a live Linux host (not
# fabricated) - a listening socket on 127.0.0.1:19845 (0x4D85) and one on
# 0.0.0.0:13306 (0x33FA), both in LISTEN state (0A - not one of
# STATE_CODES' six active states, so neither should ever count as
# "active" for drained: purposes), plus a synthetic ESTABLISHED
# connection appended to exercise the actual matching logic.
private SAMPLE = <<-TCP
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:4D85 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 6145249 1 00000000d827e4cd 100 0 0 10 0
   1: 00000000:33FA 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 6554770 1 000000005688afba 100 0 0 10 0
   2: 0100007F:4D85 0100007F:C350 01 00000000:00000000 00:00000000 00000000  1000        0 6145250 1 00000000d827e4ce 100 0 0 10 0
TCP

describe Krikri::PluginHelpers::ProcNetTcp do
  describe ".ipv4_to_hex" do
    it "converts a dotted IPv4 address to /proc/net/tcp's byte-reversed hex form" do
      Krikri::PluginHelpers::ProcNetTcp.ipv4_to_hex("127.0.0.1").must_equal("0100007F")
    end

    it "converts the any-address" do
      Krikri::PluginHelpers::ProcNetTcp.ipv4_to_hex("0.0.0.0").must_equal("00000000")
    end

    it "returns nil for a non-IPv4 value" do
      Krikri::PluginHelpers::ProcNetTcp.ipv4_to_hex("not-an-ip").must_be_nil
      Krikri::PluginHelpers::ProcNetTcp.ipv4_to_hex("::1").must_be_nil
    end
  end

  describe ".port_to_hex" do
    it "matches real /proc/net/tcp's own 4-digit uppercase hex port encoding" do
      Krikri::PluginHelpers::ProcNetTcp.port_to_hex(19845).must_equal("4D85")
      Krikri::PluginHelpers::ProcNetTcp.port_to_hex(80).must_equal("0050")
    end
  end

  describe ".parse" do
    it "skips the header line and parses each connection's local/remote address and state" do
      connections = Krikri::PluginHelpers::ProcNetTcp.parse(SAMPLE)
      connections.size.must_equal(3)
      connections[0].local_ip.must_equal("0100007F")
      connections[0].local_port.must_equal("4D85")
      connections[0].state.must_equal("0A")
      connections[2].state.must_equal("01")
      connections[2].remote_ip.must_equal("0100007F")
    end
  end

  describe ".count_active" do
    private def connections
      Krikri::PluginHelpers::ProcNetTcp.parse(SAMPLE)
    end

    it "counts only connections in an active state, matching host and port" do
      count = Krikri::PluginHelpers::ProcNetTcp.count_active(
        connections, "0100007F", "4D85",
        Krikri::PluginHelpers::ProcNetTcp::DEFAULT_ACTIVE_STATES, [] of String
      )
      count.must_equal(1)
    end

    it "does not count LISTEN (0A) connections - not one of the six active states" do
      count = Krikri::PluginHelpers::ProcNetTcp.count_active(
        connections, "0100007F", "4D85", ["ESTABLISHED"], [] of String
      )
      count.must_equal(1)

      listen_only = Krikri::PluginHelpers::ProcNetTcp.count_active(
        connections, "00000000", "33FA",
        Krikri::PluginHelpers::ProcNetTcp::DEFAULT_ACTIVE_STATES, [] of String
      )
      listen_only.must_equal(0)
    end

    it "matches a service listening/connected on 0.0.0.0 (the wildcard address) regardless of host:" do
      count = Krikri::PluginHelpers::ProcNetTcp.count_active(
        connections, "0100007F", "33FA", ["LISTEN"], [] of String
      )
      count.must_equal(0) # LISTEN isn't a real active state - sanity check
    end

    it "excludes a matching connection whose remote address is in exclude_hexes" do
      count = Krikri::PluginHelpers::ProcNetTcp.count_active(
        connections, "0100007F", "4D85",
        Krikri::PluginHelpers::ProcNetTcp::DEFAULT_ACTIVE_STATES, ["0100007F"]
      )
      count.must_equal(0)
    end

    it "only counts privilege states explicitly requested via active_connection_states" do
      count = Krikri::PluginHelpers::ProcNetTcp.count_active(
        connections, "0100007F", "4D85", ["SYN_SENT"], [] of String
      )
      count.must_equal(0)
    end
  end
end
