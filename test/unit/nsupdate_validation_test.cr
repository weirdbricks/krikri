require "../minitest_helper"

# Pins plugins/nsupdate.cr's argument-validation surface against real
# community.general.nsupdate (confirmed via
# testing/podman-diff/cases/nsupdate_edge_cases.yml cases N10/N11/N14-N16):
#
# - port/ttl/timeout are AnsibleModule type-converted (int/int/float)
#   BEFORE the choices checks, failing with parameters.py's wording
# - key_algorithm=gss-tsig + key_name fails with the Ansible module's
#   incompatibility check, which runs before any gssapi import
# - the record type is parsed only at record_exists time (dnspython's
#   UnknownRdatatype wording, after TSIG/zone setup, pre-network)
# - value validation is moment-of-use: it happens after the first probe
#   round trip, so with an unreachable server a missing or malformed
#   value fails with the connection error first, not the value error
#   (port 1 - nothing listens there, so the refused connection is
#   deterministic on any dev host)
describe "nsupdate plugin validation surface" do
  it "fails a non-integer port with the type-conversion wording" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1",
      "record" => "a.example.org.",
      "zone"   => "example.org.",
      "port"   => "not-a-port",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "argument 'port' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int"
    )
  end

  it "fails a non-integer ttl with the type-conversion wording" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1",
      "record" => "a.example.org.",
      "zone"   => "example.org.",
      "ttl"    => "not-a-ttl",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "argument 'ttl' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int"
    )
  end

  it "fails a non-float timeout with the type-conversion wording" do
    result = PluginSpecHelper.run("nsupdate", {
      "server"  => "127.0.0.1",
      "record"  => "a.example.org.",
      "zone"    => "example.org.",
      "timeout" => "not-a-timeout",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "argument 'timeout' is of type <class 'str'> and we were unable to convert to float: " \
      "<class 'str'> cannot be converted to a float"
    )
  end

  it "fails gss-tsig + key_name with the real incompatibility check" do
    result = PluginSpecHelper.run("nsupdate", {
      "server"        => "127.0.0.1",
      "record"        => "a.example.org.",
      "zone"          => "example.org.",
      "key_algorithm" => "gss-tsig",
      "key_name"      => "nsupdate",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("key_name cannot be used with GSS-TSIG")
  end

  it "fails an unknown record type with dnspython's wording" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1",
      "record" => "a.example.org.",
      "zone"   => "example.org.",
      "type"   => "NOTATYPE",
      "value"  => "192.0.2.1",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Record error: DNS resource record type is unknown.")
  end

  it "reports the connection error before a missing value (moment-of-use)" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1",
      "port"   => "1",
      "record" => "a.example.org.",
      "zone"   => "example.org.",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("DNS server error")
  end

  it "reports the connection error before a malformed value (moment-of-use)" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1",
      "port"   => "1",
      "record" => "a.example.org.",
      "zone"   => "example.org.",
      "type"   => "A",
      "value"  => "not-an-ip",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("DNS server error")
  end

  # community.general 12.3.0 added server FQDN support: from that release
  # the module resolves the server parameter (AAAA first, then A) before
  # TSIG, zone and record work, so a NAME with no answer fails ahead of
  # those checks. Confirmed against ansible-playbook (13.x) for the issue
  # #1381 playbook, where server: 19 is not an IPv4/IPv6 literal and is
  # therefore asked of DNS as a name - and never exists there - and for
  # the same playbook with a key_name but no key_secret, where the
  # resolution failure still wins.
  it "fails a numeric non-address server as unresolvable on 12.3.0+, before any TSIG work" do
    result = PluginSpecHelper.run("nsupdate", {
      "server"   => "19",
      "record"   => "33",
      "zone"     => "kpg-test.zone",
      "state"    => "absent",
      "key_name" => "key-without-secret",
    }, collection_version: "13.2.0")

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to resolve server '19' to an IP address")
  end

  # Python's ipaddress accepts only a four-strict-octet IPv4 literal, so
  # 127.0.1 is asked of DNS as a name and fails there; getaddrinfo would
  # read it as 127.0.0.1 and go on to query (confirmed against
  # ansible-playbook on the same host).
  it "fails an IPv4 shorthand server as unresolvable instead of querying 127.0.0.1" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.1",
      "record" => "33",
      "zone"   => "kpg-test.zone",
      "state"  => "absent",
    }, collection_version: "13.2.0")

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to resolve server '127.0.1' to an IP address")
  end

  it "fails an empty server as unresolvable" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "",
      "record" => "33",
      "zone"   => "kpg-test.zone",
      "state"  => "absent",
    }, collection_version: "13.2.0")

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to resolve server '' to an IP address")
  end

  # Before 12.3.0 there is no resolution at all: the raw server string goes
  # to dnspython, whose address-family probe raises a bare ValueError for
  # any non-literal. Ansible reports that uncaught crash as a message-less
  # module failure ("Task failed: Module failed."), and it happens at the
  # first network call - not up front - so the key/TSIG checks still run
  # first and the record type is still validated ahead of it (both
  # confirmed against ansible-playbook with Debian's community.general
  # 11.2.1, the release its ansible package ships).
  it "reports a non-literal server as a message-less module crash on 11.2.1" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "19",
      "record" => "33",
      "zone"   => "kpg-test.zone",
      "state"  => "absent",
    }, collection_version: "11.2.1")

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed.")
  end

  it "keeps the key_secret check ahead of the 11.2.1 crash" do
    result = PluginSpecHelper.run("nsupdate", {
      "server"   => "19",
      "record"   => "33",
      "zone"     => "kpg-test.zone",
      "state"    => "absent",
      "key_name" => "key-without-secret",
    }, collection_version: "11.2.1")

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Missing key_secret")
  end

  it "keeps the unknown record type check ahead of the 11.2.1 crash" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "19",
      "record" => "33",
      "zone"   => "kpg-test.zone",
      "state"  => "absent",
      "type"   => "NOTATYPE",
    }, collection_version: "11.2.1")

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Record error: DNS resource record type is unknown.")
  end
end
