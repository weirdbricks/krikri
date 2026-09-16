require "../spec_helper"

# Pins plugins/nsupdate.cr's argument-validation surface against real
# community.general.nsupdate (confirmed via
# testing/podman-diff/cases/nsupdate_edge_cases.yml cases N10/N11/N14-N16):
#
# - port/ttl/timeout are AnsibleModule type-converted (int/int/float)
#   BEFORE the choices checks, failing with parameters.py's wording
# - key_algorithm=gss-tsig + key_name fails with the real module's
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("key_name cannot be used with GSS-TSIG")
  end

  it "fails an unknown record type with dnspython's wording" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1",
      "record" => "a.example.org.",
      "zone"   => "example.org.",
      "type"   => "NOTATYPE",
      "value"  => "192.0.2.1",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Record error: DNS resource record type is unknown.")
  end

  it "reports the connection error before a missing value (moment-of-use)" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1",
      "port"   => "1",
      "record" => "a.example.org.",
      "zone"   => "example.org.",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("DNS server error")
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("DNS server error")
  end
end
