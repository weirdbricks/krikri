require "../spec_helper"
require "../../src/krikri/ipaddr_core"
require "../../src/krikri/variable_substitutor/filter_engine"

# ansible.utils ipaddr filter family (IpAddrCore) - every expectation
# below is mirrored from a live ansible-core 2.19.4 + ansible.utils +
# netaddr 1.3.0 probe (real ansible-playbook run on this host), not
# from the collection's docs: several documented aliases ('addr',
# 'netprefix', 'host-prefixed', 'bin', 'hex', 'reserved',
# 'unspecified') are NOT in the installed plugin's own query map and
# error there, so they error here too.
private def j(s : String) : JSON::Any
  JSON::Any.new(s)
end

private def jv(raw : Int64) : JSON::Any
  JSON::Any.new(raw)
end

describe Krikri::IpAddrCore do
  # ---- ipaddr: parse-or-false core behavior ----

  it "returns the bare address for an empty query" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1")).should eq(j("192.168.0.1"))
  end

  it "returns address/prefix for a network input" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1/24")).should eq(j("192.168.0.1/24"))
  end

  it "returns false for garbage, empty, nil, and true values" do
    Krikri::IpAddrCore.ipaddr(j("notanip")).should eq(JSON::Any.new(false))
    Krikri::IpAddrCore.ipaddr(JSON::Any.new(nil)).should eq(JSON::Any.new(false))
    Krikri::IpAddrCore.ipaddr(JSON::Any.new(true)).should eq(JSON::Any.new(false))
    Krikri::IpAddrCore.ipaddr(j("")).should eq(JSON::Any.new(false))
  end

  it "accepts an integer input (v4 first, then v6)" do
    Krikri::IpAddrCore.ipaddr(jv(3232235521_i64)).should eq(j("192.168.0.1"))
    Krikri::IpAddrCore.ipaddr(jv(3232235521_i64), "host").should eq(j("192.168.0.1/32"))
  end

  it "filters a list to its valid entries" do
    list = JSON.parse(%q(["192.168.0.1", "nope", "10.0.0.1/8"]))
    Krikri::IpAddrCore.ipaddr(list).as_a.map(&.as_s).should eq(["192.168.0.1", "10.0.0.1/8"])
  end

  # ---- ipaddr: value queries ----

  it "supports the value queries probed live" do
    v = j("192.168.0.1/24")
    {
      {"address", "192.168.0.1"},
      {"network", "192.168.0.0"},
      {"netmask", "255.255.255.0"},
      {"hostmask", "0.0.0.255"},
      {"wildcard", "0.0.0.255"},
      {"cidr", "192.168.0.1/24"},
      {"host", "192.168.0.1/24"},
      {"hostnet", "192.168.0.1/24"},
      {"int", "3232235521/24"},
      {"ip_netmask", "192.168.0.1 255.255.255.0"},
      {"network_netmask", "192.168.0.0 255.255.255.0"},
      {"network_wildcard", "192.168.0.0 0.0.0.255"},
      {"network/prefix", "192.168.0.0/24"},
      {"subnet", "192.168.0.0/24"},
      {"ip/prefix", "192.168.0.1/24"},
      {"first_usable", "192.168.0.1"},
      {"last_usable", "192.168.0.254"},
      {"range_usable", "192.168.0.1-192.168.0.254"},
      {"type", "address"},
      {"net", "false"},
      {"ip_netmask2", "x"},
    }.each do |(query, expected)|
      next if query == "ip_netmask2"
      got = Krikri::IpAddrCore.ipaddr(v, query).as_s?
      expected == "false" ? got.should(be_nil) : got.should eq(expected)
    end
  end

  it "returns integers for prefix/version/size/size_usable" do
    v = j("192.168.0.1/24")
    Krikri::IpAddrCore.ipaddr(v, "prefix").should eq(jv(24))
    Krikri::IpAddrCore.ipaddr(v, "version").should eq(jv(4))
    Krikri::IpAddrCore.ipaddr(v, "size").should eq(jv(256))
    Krikri::IpAddrCore.ipaddr(v, "size_usable").should eq(jv(254))
  end

  it "broadcast only exists for prefixes longer than /31" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1/24"), "broadcast").should eq(j("192.168.0.255"))
    Krikri::IpAddrCore.ipaddr(j("192.168.0.0/31"), "broadcast").raw.should eq(false)
    Krikri::IpAddrCore.ipaddr(j("192.168.0.0/31"), "address").should eq(j("192.168.0.0"))
  end

  it "treats a /32 network input as an address for the type query" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1/32"), "type").should eq(j("address"))
    Krikri::IpAddrCore.ipaddr(j("192.168.0.0/24"), "type").should eq(j("network"))
  end

  it "supports the address-type pass-through queries" do
    {
      {"192.168.0.1", "private", "192.168.0.1"},
      {"8.8.8.8", "private", nil},
      {"8.8.8.8", "public", "8.8.8.8"},
      {"192.168.0.1", "public", nil},
      {"127.0.0.1", "loopback", "127.0.0.1"},
      {"224.0.0.1", "multicast", "224.0.0.1"},
      {"169.254.1.1", "link-local", "169.254.1.1"},
      {"192.168.0.1", "unicast", "192.168.0.1"},
      {"100.64.0.1", "private", "100.64.0.1"},
      {"2001:db8::1", "private", "2001:db8::1"},
      {"fd00::1", "private", "fd00::1"},
      {"fe80::1", "link-local", "fe80::1"},
    }.each do |(value, query, expected)|
      got = Krikri::IpAddrCore.ipaddr(j(value), query)
      expected ? got.should(eq(j(expected))) : got.raw.should(eq(false))
    end
  end

  it "bool returns true for any valid value, false otherwise" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "bool").should eq(JSON::Any.new(true))
    Krikri::IpAddrCore.ipaddr(j("nope"), "bool").should eq(JSON::Any.new(false))
  end

  it "supports the version-mapping ipv4/ipv6 queries (netaddr quirks included)" do
    Krikri::IpAddrCore.ipaddr(j("::ffff:192.168.0.1"), "ipv4").should eq(j("192.168.0.1/32"))
    Krikri::IpAddrCore.ipaddr(j("::1"), "ipv4").should eq(j("0.0.0.1/32"))
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "ipv6").should eq(j("::ffff:192.168.0.1/128"))
  end

  it "supports the numeric-index query from the network base" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1/24"), "24").should eq(j("192.168.0.24/24"))
    Krikri::IpAddrCore.ipaddr(j("192.168.32.0/24"), "1").should eq(j("192.168.32.1/24"))
    Krikri::IpAddrCore.ipaddr(j("192.168.32.0/24"), "-1").should eq(j("192.168.32.255/24"))
    Krikri::IpAddrCore.ipaddr(j("192.168.32.0/24"), "300").raw.should eq(false)
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "0").should eq(j("192.168.0.1"))
  end

  it "supports the cidr_lookup query for containment checks" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.5"), "192.168.0.0/24").should eq(j("192.168.0.5"))
    Krikri::IpAddrCore.ipaddr(j("10.0.0.5"), "192.168.0.0/24").raw.should eq(false)
  end

  it "supports the wrap query and revdns" do
    Krikri::IpAddrCore.ipaddr(j("2001:db8::1/64"), "wrap").should eq(j("[2001:db8::1]/64"))
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "revdns").should eq(j("1.0.168.192.in-addr.arpa."))
  end

  it "errors with the real plugin's unknown-filter-type message for queries not in its map" do
    ["addr", "bin", "hex", "reserved", "unspecified", "host-prefixed", "netprefix"].each do |query|
      expect_raises(Krikri::IpAddrCore::IpError, "unknown filter type: #{query}") do
        Krikri::IpAddrCore.ipaddr(j("192.168.0.1/24"), query)
      end
    end
  end

  it "raises the real 'Not a network address' error for network-only queries on an address" do
    expect_raises(Krikri::IpAddrCore::IpError, "Not a network address") do
      Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "first_usable")
    end
  end

  # ---- ipwrap ----

  it "brackets v6, leaves v4 and garbage alone" do
    Krikri::IpAddrCore.ipwrap(j("2001:db8::1")).should eq(j("[2001:db8::1]"))
    Krikri::IpAddrCore.ipwrap(j("192.168.0.1")).should eq(j("192.168.0.1"))
    Krikri::IpAddrCore.ipwrap(j("nope")).should eq(j("nope"))
    list = JSON.parse(%q(["2001:db8::1", "192.168.0.1", "nope"]))
    Krikri::IpAddrCore.ipwrap(list).as_a.map(&.as_s).should eq(["[2001:db8::1]", "192.168.0.1", "nope"])
  end

  # ---- ipsubnet ----

  it "counts subnets of a larger network" do
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.0/24"), "25").should eq(jv(2))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.0/16"), "25").should eq(jv(512))
  end

  it "indexes subnets of a larger network" do
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.0/24"), "25", "0").should eq(j("192.168.0.0/25"))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.0/24"), "25", "-1").should eq(j("192.168.0.128/25"))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/32"), "24", "0").should eq(j("192.168.0.0/24"))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/32"), "24", "1").should eq(j("192.168.0.0/25"))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/32"), "33").raw.should eq(false)
  end

  it "finds the parent subnet of an address" do
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/32"), "24").should eq(j("192.168.0.0/24"))
  end

  it "returns the 1-based index of a subnet within a containing subnet" do
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/24"), "192.168.0.0/16").should eq(jv(1))
  end

  it "raises for a value outside the queried subnet" do
    expect_raises(Krikri::IpAddrCore::IpError, "is not in the subnet") do
      Krikri::IpAddrCore.ipsubnet(j("10.0.0.1/24"), "192.168.0.0/16")
    end
  end

  # ---- ipmath / nth / network_in_* / ip4_hex ----

  it "does address arithmetic" do
    Krikri::IpAddrCore.ipmath(j("192.168.0.5"), 10).should eq(j("192.168.0.15"))
    Krikri::IpAddrCore.ipmath(j("192.168.0.5"), -10).should eq(j("192.167.255.251"))
  end

  it "walks n usable hosts forward and backward" do
    Krikri::IpAddrCore.next_nth_usable(j("192.168.32.5/24"), 2).should eq(j("192.168.32.7"))
    Krikri::IpAddrCore.previous_nth_usable(j("192.168.32.5/24"), 3).should eq(j("192.168.32.2"))
    Krikri::IpAddrCore.next_nth_usable(j("192.168.32.250/24"), 10).raw.should eq(false)
  end

  it "checks containment including network/broadcast, or usable hosts only" do
    net = j("192.168.0.0/24")
    Krikri::IpAddrCore.network_in_network(net, j("192.168.0.255")).should eq(JSON::Any.new(true))
    Krikri::IpAddrCore.network_in_usable(net, j("192.168.0.255")).should eq(JSON::Any.new(false))
    Krikri::IpAddrCore.network_in_usable(net, j("192.168.0.4")).should eq(JSON::Any.new(true))
    Krikri::IpAddrCore.network_in_network(net, j("10.0.0.1")).should eq(JSON::Any.new(false))
  end

  it "formats hex octets" do
    Krikri::IpAddrCore.ip4_hex(j("192.168.0.1")).should eq(j("c0a80001"))
    Krikri::IpAddrCore.ip4_hex(j("192.168.0.1"), ".").should eq(j("c0.a8.00.01"))
  end

  # ---- FilterEngine integration (the `{{ }}` evaluator path) ----

  it "resolves through FilterEngine with the ansible.utils FQCN spelling" do
    engine = Krikri::VariableSubstitutor::FilterEngine.new
    engine.apply(j("192.168.0.1/24"), "ipaddr('network')").should eq(j("192.168.0.0"))
    engine.apply(j("192.168.0.1/24"), "ansible.utils.ipaddr('network')").should eq(j("192.168.0.0"))
  end

  it "still errors with the full FQCN for an unknown ansible.utils filter" do
    engine = Krikri::VariableSubstitutor::FilterEngine.new
    expect_raises(
      Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError,
      "No filter named 'ansible.utils.nope'."
    ) do
      engine.apply(j("x"), "ansible.utils.nope")
    end
  end

  it "list inputs flatten through the FilterEngine path" do
    engine = Krikri::VariableSubstitutor::FilterEngine.new
    list = JSON.parse(%q(["2001:db8::1", "192.168.0.1", "nope"]))
    engine.apply(list, "ipwrap").as_a.map(&.as_s).should eq(["[2001:db8::1]", "192.168.0.1", "nope"])
  end
end
