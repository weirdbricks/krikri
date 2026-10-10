require "../minitest_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Round 5300009 (ktechmidas.openvpn recurrence of round 5210000's pending
# bug): the warm run of a role whose cold run had enabled ufw and added
# MASQUERADE/forwarding state died with a bare "Index out of bounds"
# during facts gathering - pinpointed to the network section only by the
# new "(while gathering network)" annotation. The laptop's normal
# network state never reproduced it, so the trigger was one `ip addr`
# line shape the changed host produced; the unguarded spot the audit
# found was the octet indexing behind the per-"inet"-line address
# parsing, now `ipv4_quad_octets?` + `parse_ipv4_addr_output`. These
# pins feed suspicious line shapes through the parser directly: every
# shape must come back as a parsed entry or a SKIP, never a crash.
describe "Krikri::FactsGatherer (facts_network_addr_parse_test.cr)" do
  describe "#parse_ipv4_addr_output" do
    it "parses a normal inet line into address/netmask/network" do
      entries = Krikri::FactsGatherer.parse_ipv4_addr_output(
        "2: eth0    inet 10.0.0.1/24 scope global eth0\n"
      )

      entries.size.must_equal(1)
      entries[0]["address"].as_s.must_equal("10.0.0.1")
      entries[0]["netmask"].as_s.must_equal("255.255.255.0")
      entries[0]["network"].as_s.must_equal("10.0.0.0")
      entries[0]["broadcast"]?.must_be_nil
    end

    it "keeps the broadcast of a brd line, including the ufw-era dynamic/secondary shapes" do
      entries = Krikri::FactsGatherer.parse_ipv4_addr_output(
        "3: eth0    inet 10.8.0.2/24 brd 10.8.0.255 scope global dynamic eth0\n" \
        "2: eth0    inet 192.168.1.5/16 brd 192.168.255.255 scope global secondary eth0\n"
      )

      entries.size.must_equal(2)
      entries[0]["address"].as_s.must_equal("10.8.0.2")
      entries[0]["broadcast"].as_s.must_equal("10.8.0.255")
      entries[1]["netmask"].as_s.must_equal("255.255.0.0")
      entries[1]["network"].as_s.must_equal("192.168.0.0")
    end

    it "skips an inet line whose address has no /prefix, without crashing" do
      # The visible crash was lost inside the annotation wrapper, so the
      # exact on-host shape is unknown; a peer-addressed (point-to-point)
      # line like openvpn's presents the local address WITHOUT the / -
      # per Ansible this is no parsed entry at all.
      entries = Krikri::FactsGatherer.parse_ipv4_addr_output(
        "2: tun0    inet 10.8.0.2 peer 10.8.0.1\n"
      )

      entries.must_be_empty
    end

    it "skips an inet line whose address is the suspected no-inet / fewer-octet shape instead of indexing out of bounds" do
      # The literal regression: the previous parse split the address on
      # dots and indexed octets unguarded, so ANY "inet" whose address
      # is not exactly four octets raised "Index out of bounds" (or an
      # ArgumentError from a numeric conversion); only the first three
      # shapes could even reach that indexing, all four are pinned now.
      entries = Krikri::FactsGatherer.parse_ipv4_addr_output(
        "2: tun0    inet 10.0.0/24\n" \
        "3: tun0    inet 10/8\n" \
        "4: tun0    inet 10.8.0.1.2/24\n" \
        "5: tun0    inet 10.eight.0.1/24\n" \
        "6: tun0    inet 10.300.0.1/24\n"
      )

      entries.must_be_empty
    end

    it "skips inet lines with no address field at all" do
      entries = Krikri::FactsGatherer.parse_ipv4_addr_output(
        "2: lo    inet\n"
      )

      entries.must_be_empty
    end

    it "skips `ip`'s continuation and non-inet lines (empty-proc-net-dev-shaped input)" do
      entries = Krikri::FactsGatherer.parse_ipv4_addr_output(
        "       valid_lft forever preferred_lft forever\n" \
        "2: eth0    inet6 fe80::5054:ff:fe39:9d31/64 scope link\n" \
        "\n"
      )

      entries.must_be_empty
    end

    it "returns no entries for empty output (an interface with no IPv4 address)" do
      Krikri::FactsGatherer.parse_ipv4_addr_output("").must_be_empty
    end

    it "still skips a truncated brd line rather than crashing on a missing broadcast field" do
      entries = Krikri::FactsGatherer.parse_ipv4_addr_output(
        "2: eth0    inet 10.0.0.1/24 brd\n"
      )

      entries.size.must_equal(1)
      entries[0]["broadcast"]?.must_be_nil
    end
  end

  describe "#parse_ipv6_addr_output" do
    it "parses an inet6 line with scope into address/prefix/scope" do
      entries = Krikri::FactsGatherer.parse_ipv6_addr_output(
        "2: eth0    inet6 fe80::5054:ff:fe39:9d31/64 scope link\n"
      )

      entries.size.must_equal(1)
      entries[0]["address"].as_s.must_equal("fe80::5054:ff:fe39:9d31")
      entries[0]["prefix"].as_s.must_equal("64")
      entries[0]["scope"].as_s.must_equal("link")
    end

    it "keeps an inet6 line that has no scope field, without crashing" do
      entries = Krikri::FactsGatherer.parse_ipv6_addr_output(
        "2: wg0    inet6 fd00::5/64\n"
      )

      entries.size.must_equal(1)
      entries[0]["scope"]?.must_be_nil
    end

    it "skips non-inet6 and bare-continuation lines" do
      entries = Krikri::FactsGatherer.parse_ipv6_addr_output(
        "       valid_lft forever preferred_lft forever\n" \
        "2: eth0    inet 10.0.0.1/24 scope global eth0\n" \
        "\n"
      )

      entries.must_be_empty
    end

    it "skips a prefix-less inet6 line instead of crashing on the one-element split" do
      entries = Krikri::FactsGatherer.parse_ipv6_addr_output(
        "2: wg0    inet6 fe80::5\n"
      )

      entries.must_be_empty
    end

    it "returns no entries for empty output" do
      Krikri::FactsGatherer.parse_ipv6_addr_output("").must_be_empty
    end
  end
end
