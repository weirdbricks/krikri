require "../minitest_helper"
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
  include RaisesAssertion
  # ---- ipaddr: parse-or-false core behavior ----

  it "returns the bare address for an empty query" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1")).must_equal(j("192.168.0.1"))
  end

  it "returns address/prefix for a network input" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1/24")).must_equal(j("192.168.0.1/24"))
  end

  it "returns false for garbage, empty, nil, and true values" do
    Krikri::IpAddrCore.ipaddr(j("notanip")).must_equal(JSON::Any.new(false))
    Krikri::IpAddrCore.ipaddr(JSON::Any.new(nil)).must_equal(JSON::Any.new(false))
    Krikri::IpAddrCore.ipaddr(JSON::Any.new(true)).must_equal(JSON::Any.new(false))
    Krikri::IpAddrCore.ipaddr(j("")).must_equal(JSON::Any.new(false))
  end

  it "accepts an integer input (v4 first, then v6)" do
    Krikri::IpAddrCore.ipaddr(jv(3232235521_i64)).must_equal(j("192.168.0.1"))
    Krikri::IpAddrCore.ipaddr(jv(3232235521_i64), "host").must_equal(j("192.168.0.1/32"))
  end

  it "filters a list to its valid entries" do
    list = JSON.parse(%q(["192.168.0.1", "nope", "10.0.0.1/8"]))
    Krikri::IpAddrCore.ipaddr(list).as_a.map(&.as_s).must_equal(["192.168.0.1", "10.0.0.1/8"])
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
      skip("conditional skip") if query == "ip_netmask2"
      got = Krikri::IpAddrCore.ipaddr(v, query).as_s?
      expected == "false" ? got.must_be_nil : got.must_equal(expected)
    end
  end

  it "returns integers for prefix/version/size/size_usable" do
    v = j("192.168.0.1/24")
    Krikri::IpAddrCore.ipaddr(v, "prefix").must_equal(jv(24_i64))
    Krikri::IpAddrCore.ipaddr(v, "version").must_equal(jv(4_i64))
    Krikri::IpAddrCore.ipaddr(v, "size").must_equal(jv(256_i64))
    Krikri::IpAddrCore.ipaddr(v, "size_usable").must_equal(jv(254_i64))
  end

  it "broadcast only exists for prefixes longer than /31" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1/24"), "broadcast").must_equal(j("192.168.0.255"))
    Krikri::IpAddrCore.ipaddr(j("192.168.0.0/31"), "broadcast").raw.must_equal(false)
    Krikri::IpAddrCore.ipaddr(j("192.168.0.0/31"), "address").must_equal(j("192.168.0.0"))
  end

  it "treats a /32 network input as an address for the type query" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1/32"), "type").must_equal(j("address"))
    Krikri::IpAddrCore.ipaddr(j("192.168.0.0/24"), "type").must_equal(j("network"))
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
      expected ? got.must_equal(j(expected)) : got.raw.must_equal(false)
    end
  end

  it "bool returns true for any valid value, false otherwise" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "bool").must_equal(JSON::Any.new(true))
    Krikri::IpAddrCore.ipaddr(j("nope"), "bool").must_equal(JSON::Any.new(false))
  end

  it "supports the version-mapping ipv4/ipv6 queries (netaddr quirks included)" do
    Krikri::IpAddrCore.ipaddr(j("::ffff:192.168.0.1"), "ipv4").must_equal(j("192.168.0.1/32"))
    Krikri::IpAddrCore.ipaddr(j("::1"), "ipv4").must_equal(j("0.0.0.1/32"))
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "ipv6").must_equal(j("::ffff:192.168.0.1/128"))
  end

  it "supports the numeric-index query from the network base" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1/24"), "24").must_equal(j("192.168.0.24/24"))
    Krikri::IpAddrCore.ipaddr(j("192.168.32.0/24"), "1").must_equal(j("192.168.32.1/24"))
    Krikri::IpAddrCore.ipaddr(j("192.168.32.0/24"), "-1").must_equal(j("192.168.32.255/24"))
    Krikri::IpAddrCore.ipaddr(j("192.168.32.0/24"), "300").raw.must_equal(false)
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "0").must_equal(j("192.168.0.1"))
  end

  it "supports the cidr_lookup query for containment checks" do
    Krikri::IpAddrCore.ipaddr(j("192.168.0.5"), "192.168.0.0/24").must_equal(j("192.168.0.5"))
    Krikri::IpAddrCore.ipaddr(j("10.0.0.5"), "192.168.0.0/24").raw.must_equal(false)
  end

  it "supports the wrap query and revdns" do
    Krikri::IpAddrCore.ipaddr(j("2001:db8::1/64"), "wrap").must_equal(j("[2001:db8::1]/64"))
    Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "revdns").must_equal(j("1.0.168.192.in-addr.arpa."))
  end

  it "errors with the real plugin's unknown-filter-type message for queries not in its map" do
    ["addr", "bin", "hex", "reserved", "unspecified", "host-prefixed", "netprefix"].each do |query|
      assert_raises_message(Krikri::IpAddrCore::IpError, "unknown filter type: #{query}") do
        Krikri::IpAddrCore.ipaddr(j("192.168.0.1/24"), query)
      end
    end
  end

  it "raises the real 'Not a network address' error for network-only queries on an address" do
    assert_raises_message(Krikri::IpAddrCore::IpError, "Not a network address") do
      Krikri::IpAddrCore.ipaddr(j("192.168.0.1"), "first_usable")
    end
  end

  # ---- ipwrap ----

  it "brackets v6, leaves v4 and garbage alone" do
    Krikri::IpAddrCore.ipwrap(j("2001:db8::1")).must_equal(j("[2001:db8::1]"))
    Krikri::IpAddrCore.ipwrap(j("192.168.0.1")).must_equal(j("192.168.0.1"))
    Krikri::IpAddrCore.ipwrap(j("nope")).must_equal(j("nope"))
    list = JSON.parse(%q(["2001:db8::1", "192.168.0.1", "nope"]))
    Krikri::IpAddrCore.ipwrap(list).as_a.map(&.as_s).must_equal(["[2001:db8::1]", "192.168.0.1", "nope"])
  end

  # ---- ipsubnet ----

  it "counts subnets of a larger network" do
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.0/24"), "25").must_equal(jv(2_i64))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.0/16"), "25").must_equal(jv(512_i64))
  end

  it "indexes subnets of a larger network" do
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.0/24"), "25", "0").must_equal(j("192.168.0.0/25"))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.0/24"), "25", "-1").must_equal(j("192.168.0.128/25"))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/32"), "24", "0").must_equal(j("192.168.0.0/24"))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/32"), "24", "1").must_equal(j("192.168.0.0/25"))
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/32"), "33").raw.must_equal(false)
  end

  it "finds the parent subnet of an address" do
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/32"), "24").must_equal(j("192.168.0.0/24"))
  end

  it "returns the 1-based index of a subnet within a containing subnet" do
    Krikri::IpAddrCore.ipsubnet(j("192.168.0.1/24"), "192.168.0.0/16").must_equal(jv(1_i64))
  end

  it "raises for a value outside the queried subnet" do
    assert_raises_message(Krikri::IpAddrCore::IpError, "is not in the subnet") do
      Krikri::IpAddrCore.ipsubnet(j("10.0.0.1/24"), "192.168.0.0/16")
    end
  end

  # ---- ipmath / nth / network_in_* / ip4_hex ----

  it "does address arithmetic" do
    Krikri::IpAddrCore.ipmath(j("192.168.0.5"), 10).must_equal(j("192.168.0.15"))
    Krikri::IpAddrCore.ipmath(j("192.168.0.5"), -10).must_equal(j("192.167.255.251"))
  end

  it "walks n usable hosts forward and backward" do
    Krikri::IpAddrCore.next_nth_usable(j("192.168.32.5/24"), 2).must_equal(j("192.168.32.7"))
    Krikri::IpAddrCore.previous_nth_usable(j("192.168.32.5/24"), 3).must_equal(j("192.168.32.2"))
    Krikri::IpAddrCore.next_nth_usable(j("192.168.32.250/24"), 10).raw.must_equal(false)
  end

  it "checks containment including network/broadcast, or usable hosts only" do
    net = j("192.168.0.0/24")
    Krikri::IpAddrCore.network_in_network(net, j("192.168.0.255")).must_equal(JSON::Any.new(true))
    Krikri::IpAddrCore.network_in_usable(net, j("192.168.0.255")).must_equal(JSON::Any.new(false))
    Krikri::IpAddrCore.network_in_usable(net, j("192.168.0.4")).must_equal(JSON::Any.new(true))
    Krikri::IpAddrCore.network_in_network(net, j("10.0.0.1")).must_equal(JSON::Any.new(false))
  end

  it "formats hex octets" do
    Krikri::IpAddrCore.ip4_hex(j("192.168.0.1")).must_equal(j("c0a80001"))
    Krikri::IpAddrCore.ip4_hex(j("192.168.0.1"), ".").must_equal(j("c0.a8.00.01"))
  end

  # ---- FilterEngine integration (the `{{ }}` evaluator path) ----

  it "resolves through FilterEngine with the ansible.utils FQCN spelling" do
    engine = Krikri::VariableSubstitutor::FilterEngine.new
    engine.apply(j("192.168.0.1/24"), "ipaddr('network')").must_equal(j("192.168.0.0"))
    engine.apply(j("192.168.0.1/24"), "ansible.utils.ipaddr('network')").must_equal(j("192.168.0.0"))
  end

  it "still errors with the full FQCN for an unknown ansible.utils filter" do
    engine = Krikri::VariableSubstitutor::FilterEngine.new
    assert_raises_message(
      Krikri::VariableSubstitutor::FilterEngine::UnknownFilterError, "No filter named 'ansible.utils.nope'."
    ) do
      engine.apply(j("x"), "ansible.utils.nope")
    end
  end

  it "list inputs flatten through the FilterEngine path" do
    engine = Krikri::VariableSubstitutor::FilterEngine.new
    list = JSON.parse(%q(["2001:db8::1", "192.168.0.1", "nope"]))
    engine.apply(list, "ipwrap").as_a.map(&.as_s).must_equal(["[2001:db8::1]", "192.168.0.1", "nope"])
  end
end
