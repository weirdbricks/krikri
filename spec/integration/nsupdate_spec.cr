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

  it "fails on an unknown record type" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "type" => "DHCID",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("unknown record type")
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

  it "fails when state=present without a value" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "state" => "present",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value needed when state=present")
  end

  it "fails cleanly when the DNS server refuses the connection" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "port" => "1",
      "record" => "host.example.com.", "zone" => "example.com.", "state" => "absent",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("DNS server error")
  end

  it "fails with Invalid/malformed value for a bad record value" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "port" => "1",
      "record" => "host.example.com.", "zone" => "example.com.",
      "type" => "A", "value" => "not-an-ip-address",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Invalid/malformed value")
  end
end
