require "../spec_helper"

# nsupdate's parameter-validation failures and its offline failure
# path (connection refused), exercised without a DNS server. The real
# RFC2136 create/modify/delete flows - and the TSIG-authenticated
# updates they need - belong to the live benchmark rounds.
describe "nsupdate plugin" do
  it "fails when server is missing" do
    result = PluginSpecHelper.run("nsupdate", {"record" => "host.example.com."})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("server")
  end

  it "fails when record is missing" do
    result = PluginSpecHelper.run("nsupdate", {"server" => "127.0.0.1"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("record")
  end

  it "fails when record is empty" do
    result = PluginSpecHelper.run("nsupdate", {"server" => "127.0.0.1", "record" => ""})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("record cannot be empty")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "state" => "bogus",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of state must be one of")
  end

  it "fails on an invalid protocol" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "protocol" => "carrier-pigeon",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of protocol must be one of")
  end

  it "fails on an unknown record type (pre-network, dnspython wording)" do
    # DHCID is a valid dnspython type (real Ansible accepts it and proceeds
    # to the network); the unknown-type wording is confirmed for truly
    # unknown types via podman-diff case N14 - and it fires before any
    # traffic, so the unreachable server never matters here.
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.",
      "zone"   => "example.com.", "type" => "NOTATYPE",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Record error: DNS resource record type is unknown.")
  end

  it "fails on an invalid key_algorithm" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "key_algorithm" => "hmac-md6",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of key_algorithm must be one of")
  end

  it "fails explicitly on gss-tsig (deliberate limitation)" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "key_algorithm" => "gss-tsig",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("gss-tsig")
  end

  it "reports the connection error before a missing value (moment-of-use)" do
    # real nsupdate only checks the value inside create_record, after the
    # record-exists probe round trip - with no server, the connection
    # error wins (podman-diff case N16)
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "port" => "1",
      "record" => "host.example.com.", "zone" => "example.com.", "state" => "present",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("DNS server error")
  end

  it "fails cleanly when the DNS server refuses the connection" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "port" => "1",
      "record" => "host.example.com.", "zone" => "example.com.", "state" => "absent",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("DNS server error")
  end

  it "reports the connection error before a malformed value (moment-of-use)" do
    # same moment-of-use validation: the connection error wins first
    # (podman-diff case N15)
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "port" => "1",
      "record" => "host.example.com.", "zone" => "example.com.",
      "type" => "A", "value" => "not-an-ip-address",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("DNS server error")
  end
end
