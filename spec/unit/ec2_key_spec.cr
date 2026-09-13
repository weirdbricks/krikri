require "../spec_helper"
require "json"
require "../../src/krikri/plugin_helpers/ec2_api"
require "../../src/krikri/plugin_helpers/ec2_key"

# Decision-logic specs for amazon.aws.ec2_key. Everything below runs
# through the Ec2Api transport seam (no network): the describe result is
# canned XML fed straight to the parse/plan helpers, and the full-module
# examples route the signed POSTs through a recording fake.
private DESCRIBE_ONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeKeyPairsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-1</requestId>
    <keyPairsSet>
      <item>
        <keyName>deploy</keyName>
        <keyFingerprint>aa:bb:cc</keyFingerprint>
        <keyPairId>key-123</keyPairId>
      </item>
    </keyPairsSet>
  </DescribeKeyPairsResponse>
XML

private DESCRIBE_NONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeKeyPairsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-2</requestId>
    <keyPairsSet/>
  </DescribeKeyPairsResponse>
XML

private def parse(xml : String)
  Krikri::PluginHelpers::Ec2Key.parse_key_pairs(XML.parse(xml).root.not_nil!)
end

private def run_module(params : Hash(String, String), handler : Proc(String, String, String)) : JSON::Any
  Krikri::PluginHelpers::Ec2Api.transport = handler
  begin
    result = Krikri::PluginHelpers::Ec2Key.run(params)
    JSON.parse(result.to_json)
  ensure
    Krikri::PluginHelpers::Ec2Api.transport = nil
  end
end

describe Krikri::PluginHelpers::Ec2Key do
  around_each do |example|
    # The module resolves credentials from the environment - pin them so
    # the specs neither depend on the runner's real AWS env nor leak into
    # it.
    old_access = ENV["AWS_ACCESS_KEY_ID"]?
    old_secret = ENV["AWS_SECRET_ACCESS_KEY"]?
    ENV["AWS_ACCESS_KEY_ID"] = "test-access"
    ENV["AWS_SECRET_ACCESS_KEY"] = "test-secret"
    begin
      example.run
    ensure
      if old_access
        ENV["AWS_ACCESS_KEY_ID"] = old_access
      else
        ENV.delete("AWS_ACCESS_KEY_ID")
      end
      if old_secret
        ENV["AWS_SECRET_ACCESS_KEY"] = old_secret
      else
        ENV.delete("AWS_SECRET_ACCESS_KEY")
      end
    end
  end

  describe ".parse_key_pairs" do
    it "reads keyPairsSet items" do
      keys = parse(DESCRIBE_ONE)
      keys.size.should eq(1)
      keys[0].name.should eq("deploy")
      keys[0].fingerprint.should eq("aa:bb:cc")
    end

    it "returns an empty list for an empty set" do
      parse(DESCRIBE_NONE).should eq([] of Krikri::PluginHelpers::Ec2Key::KeyPair)
    end
  end

  describe ".plan_present" do
    existing = [Krikri::PluginHelpers::Ec2Key::KeyPair.new("deploy", "aa:bb:cc")]

    it "creates a new key pair when none exists" do
      plan = Krikri::PluginHelpers::Ec2Key.plan_present("deploy", nil, false, [] of Krikri::PluginHelpers::Ec2Key::KeyPair)
      plan.changed.should be_true
      plan.steps.map(&.action).should eq(["CreateKeyPair"])
      plan.steps[0].params.should contain({"KeyName", "deploy"})
    end

    it "imports when key_material is given" do
      plan = Krikri::PluginHelpers::Ec2Key.plan_present("deploy", "ssh-rsa AAAA", false, [] of Krikri::PluginHelpers::Ec2Key::KeyPair)
      plan.changed.should be_true
      plan.steps.map(&.action).should eq(["ImportKeyPair"])
      plan.steps[0].params.should contain({"PublicKeyMaterial", "ssh-rsa AAAA"})
    end

    it "is a no-op when the key exists and force is not set" do
      plan = Krikri::PluginHelpers::Ec2Key.plan_present("deploy", nil, false, existing)
      plan.changed.should be_false
      plan.steps.should be_empty
      plan.fingerprint.should eq("aa:bb:cc")
    end

    it "leaves an existing key alone even with key_material unless forced" do
      plan = Krikri::PluginHelpers::Ec2Key.plan_present("deploy", "ssh-rsa AAAA", false, existing)
      plan.changed.should be_false
      plan.steps.should be_empty
    end

    it "deletes and recreates when force is set" do
      plan = Krikri::PluginHelpers::Ec2Key.plan_present("deploy", nil, true, existing)
      plan.changed.should be_true
      plan.steps.map(&.action).should eq(["DeleteKeyPair", "CreateKeyPair"])
    end
  end

  describe ".plan_absent" do
    it "deletes an existing key" do
      existing = [Krikri::PluginHelpers::Ec2Key::KeyPair.new("deploy", "aa:bb:cc")]
      plan = Krikri::PluginHelpers::Ec2Key.plan_absent("deploy", existing)
      plan.changed.should be_true
      plan.steps.map(&.action).should eq(["DeleteKeyPair"])
    end

    it "is a no-op when absent" do
      plan = Krikri::PluginHelpers::Ec2Key.plan_absent("deploy", [] of Krikri::PluginHelpers::Ec2Key::KeyPair)
      plan.changed.should be_false
      plan.steps.should be_empty
    end
  end

  describe ".run" do
    it "creates a key pair and returns the private key from the create response" do
      result = run_module({"name" => "deploy", "state" => "present", "region" => "us-east-1"}, ->(region : String, body : String) do
        action = URI::Params.parse(body)["Action"]
        if action == "DescribeKeyPairs"
          DESCRIBE_NONE
        else
          <<-XML
            <#{action}Response xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
              <keyName>deploy</keyName>
              <keyFingerprint>de:ad:be:ef</keyFingerprint>
              <keyMaterial>RSA PRIVATE KEY</keyMaterial>
              <keyPairId>key-9</keyPairId>
            </#{action}Response>
          XML
        end
      end)

      result["changed"].should eq(true)
      result["failed"]?.should be_falsey
      result["private_key"].should eq("RSA PRIVATE KEY")
      result["fingerprint"].should eq("de:ad:be:ef")
      result["name"].should eq("deploy")
    end

    it "sends the key-name filter on the describe call" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        DESCRIBE_NONE
      end
      run_module({"name" => "deploy", "state" => "present", "region" => "us-east-1"}, handler)
      describe_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "DescribeKeyPairs" }.not_nil!
      describe_body.should contain("Filter.1.Name=key-name")
      describe_body.should contain("Filter.1.Value.1=deploy")
    end

    it "is a no-op when the key already exists and force is not set" do
      result = run_module({"name" => "deploy", "state" => "present", "region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_ONE })
      result["changed"].should eq(false)
      result["fingerprint"].should eq("aa:bb:cc")
    end

    it "fails with the API error message when a call errors" do
      result = run_module({"name" => "deploy", "state" => "present", "region" => "us-east-1"}, ->(region : String, body : String) { raise Krikri::PluginHelpers::Ec2Api::Error.new("UnauthorizedOperation: fake") })
      result["failed"].should eq(true)
      result["msg"].should eq("UnauthorizedOperation: fake")
    end

    it "fails on a missing name" do
      result = run_module({"state" => "present", "region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_NONE })
      result["failed"].should eq(true)
      result["msg"].as_s.should contain("name")
    end
  end
end
