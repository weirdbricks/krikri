require "../spec_helper"
require "json"
require "../../src/krikri/plugin_helpers/ec2_api"
require "../../src/krikri/plugin_helpers/ec2_info"

# Read-only lookup specs for amazon.aws.ec2_vpc_subnet_info. Everything
# runs through the Ec2Api transport seam (no network): canned
# DescribeSubnets XML in, assertions on the shaped `subnets` result and
# the exact form bodies the module sends.
private DESCRIBE_ONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeSubnetsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-1</requestId>
    <subnetSet>
      <item>
        <subnetId>subnet-aaaa</subnetId>
        <subnetArn>arn:aws:ec2:us-east-1:123456789012:subnet/subnet-aaaa</subnetArn>
        <vpcId>vpc-1234</vpcId>
        <cidrBlock>10.0.1.0/24</cidrBlock>
        <availabilityZone>us-east-1a</availabilityZone>
        <availabilityZoneId>use1-az6</availabilityZoneId>
        <state>available</state>
        <availableIpAddressCount>251</availableIpAddressCount>
        <defaultForAz>false</defaultForAz>
        <mapPublicIpOnLaunch>true</mapPublicIpOnLaunch>
        <assignIpv6AddressOnCreation>false</assignIpv6AddressOnCreation>
        <ownerId>123456789012</ownerId>
        <tagSet>
          <item><key>Name</key><value>web</value></item>
          <item><key>env</key><value>staging</value></item>
        </tagSet>
        <ipv6CidrBlockAssociationSet>
          <item>
            <associationId>subnet-cidr-assoc-1</associationId>
            <ipv6CidrBlock>2001:db8::/64</ipv6CidrBlock>
            <ipv6CidrBlockState><state>associated</state></ipv6CidrBlockState>
          </item>
        </ipv6CidrBlockAssociationSet>
      </item>
    </subnetSet>
  </DescribeSubnetsResponse>
XML

private DESCRIBE_NONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeSubnetsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-2</requestId>
    <subnetSet/>
  </DescribeSubnetsResponse>
XML

private EMPTY_PARAMS = Hash(String, String).new

private def run_module(params : Hash(String, String), handler : Proc(String, String, String)) : JSON::Any
  Krikri::PluginHelpers::Ec2Api.transport = handler
  begin
    result = Krikri::PluginHelpers::Ec2Info.run_subnets(params)
    JSON.parse(result.to_json)
  ensure
    Krikri::PluginHelpers::Ec2Api.transport = nil
  end
end

describe Krikri::PluginHelpers::Ec2Info do
  around_each do |example|
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

  describe ".run_subnets" do
    it "shapes a subnet with the real module's field names" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_ONE })

      result["failed"].should eq(false)
      subnet = result["subnets"][0]
      subnet["id"].should eq("subnet-aaaa")
      subnet["subnet_id"].should eq("subnet-aaaa")
      subnet["subnet_arn"].should eq("arn:aws:ec2:us-east-1:123456789012:subnet/subnet-aaaa")
      subnet["vpc_id"].should eq("vpc-1234")
      subnet["cidr_block"].should eq("10.0.1.0/24")
      subnet["availability_zone"].should eq("us-east-1a")
      subnet["availability_zone_id"].should eq("use1-az6")
      subnet["state"].should eq("available")
      subnet["available_ip_address_count"].should eq("251")
      subnet["default_for_az"].should eq(false)
      subnet["map_public_ip_on_launch"].should eq(true)
      subnet["assign_ipv6_address_on_creation"].should eq(false)
      subnet["owner_id"].should eq("123456789012")
      subnet["tags"]["Name"].should eq("web")
      subnet["tags"]["env"].should eq("staging")
    end

    it "shapes the nested ipv6 association set" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_ONE })
      v6 = result["subnets"][0]["ipv6_cidr_block_association_set"][0]
      v6["association_id"].should eq("subnet-cidr-assoc-1")
      v6["ipv6_cidr_block"].should eq("2001:db8::/64")
      v6["ipv6_cidr_block_state"]["state"].should eq("associated")
    end

    it "returns an empty list when no subnets match" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_NONE })
      result["subnets"].as_a.should be_empty
    end

    it "sends SubnetId.N and Filter.N.Name/Value.M wire params" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        DESCRIBE_NONE
      end
      run_module({
        "region"     => "us-east-1",
        "subnet_ids" => %(["subnet-aaaa", "subnet-bbbb"]),
        "filters"    => %({"vpc-id": "vpc-1234", "tag:Name": ["web", "db"]}),
      }, handler)

      body = bodies.first.not_nil!
      params = URI::Params.parse(body)
      params.fetch_all("SubnetId.1").should eq(["subnet-aaaa"])
      params.fetch_all("SubnetId.2").should eq(["subnet-bbbb"])
      params.fetch_all("Filter.1.Name").should eq(["vpc-id"])
      params.fetch_all("Filter.1.Value.1").should eq(["vpc-1234"])
      params.fetch_all("Filter.2.Name").should eq(["tag:Name"])
      params.fetch_all("Filter.2.Value.1").should eq(["web"])
      params.fetch_all("Filter.2.Value.2").should eq(["db"])
    end

    it "fails with the API error message when a call errors" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { raise Krikri::PluginHelpers::Ec2Api::Error.new("UnauthorizedOperation: fake") })
      result["failed"].should eq(true)
      result["msg"].should eq("UnauthorizedOperation: fake")
    end

    it "fails without a region" do
      old_region = ENV["AWS_REGION"]?
      ENV.delete("AWS_REGION")
      ENV.delete("AWS_DEFAULT_REGION")
      begin
        result = run_module(EMPTY_PARAMS, ->(region : String, body : String) { DESCRIBE_NONE })
        result["failed"].should eq(true)
        result["msg"].as_s.should contain("region")
      ensure
        ENV["AWS_REGION"] = old_region if old_region
      end
    end
  end
end
