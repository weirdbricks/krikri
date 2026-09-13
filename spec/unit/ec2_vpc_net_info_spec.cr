require "../spec_helper"
require "json"
require "../../src/krikri/plugin_helpers/ec2_api"
require "../../src/krikri/plugin_helpers/ec2_info"

# Read-only lookup specs for amazon.aws.ec2_vpc_net_info. Everything
# runs through the Ec2Api transport seam (no network): canned
# DescribeVpcs + DescribeVpcAttribute XML in, assertions on the shaped
# `vpcs` result and the exact form bodies the module sends.
private DESCRIBE_ONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeVpcsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-1</requestId>
    <vpcSet>
      <item>
        <vpcId>vpc-1234</vpcId>
        <cidrBlock>10.0.0.0/16</cidrBlock>
        <state>available</state>
        <isDefault>true</isDefault>
        <instanceTenancy>default</instanceTenancy>
        <dhcpOptionsId>dopt-1</dhcpOptionsId>
        <ownerId>123456789012</ownerId>
        <cidrBlockAssociationSet>
          <item>
            <associationId>vpc-cidr-assoc-0</associationId>
            <cidrBlock>10.0.0.0/16</cidrBlock>
            <cidrBlockState><state>associated</state></cidrBlockState>
          </item>
        </cidrBlockAssociationSet>
        <tagSet>
          <item><key>Name</key><value>main</value></item>
        </tagSet>
      </item>
    </vpcSet>
  </DescribeVpcsResponse>
XML

private DESCRIBE_NONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeVpcsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-2</requestId>
    <vpcSet/>
  </DescribeVpcsResponse>
XML

private def attribute_response(attribute : String, value : String) : String
  <<-XML
    <DescribeVpcAttributeResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
      <requestId>req-3</requestId>
      <vpcId>vpc-1234</vpcId>
      <#{attribute}><value>#{value}</value></#{attribute}>
    </DescribeVpcAttributeResponse>
  XML
end

private def run_module(params : Hash(String, String), handler : Proc(String, String, String)) : JSON::Any
  Krikri::PluginHelpers::Ec2Api.transport = handler
  begin
    result = Krikri::PluginHelpers::Ec2Info.run_vpcs(params)
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

  describe ".run_vpcs" do
    it "shapes a VPC with the real module's field names, DNS attributes included" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) do
        action = URI::Params.parse(body)["Action"]
        case action
        when "DescribeVpcs"                    then DESCRIBE_ONE
        when "DescribeVpcAttribute"            then
          attribute = URI::Params.parse(body)["Attribute"]
          attribute_response(attribute, attribute == "enableDnsSupport" ? "true" : "false")
        else
          raise "unexpected action #{action}"
        end
      end)

      result["failed"]?.should be_falsey
      vpc = result["vpcs"][0]
      vpc["id"].should eq("vpc-1234")
      vpc["vpc_id"].should eq("vpc-1234")
      vpc["cidr_block"].should eq("10.0.0.0/16")
      vpc["state"].should eq("available")
      vpc["is_default"].should eq(true)
      vpc["instance_tenancy"].should eq("default")
      vpc["dhcp_options_id"].should eq("dopt-1")
      vpc["owner_id"].should eq("123456789012")
      vpc["enable_dns_support"].should eq(true)
      vpc["enable_dns_hostnames"].should eq(false)
      vpc["tags"]["Name"].should eq("main")
      assoc = vpc["cidr_block_association_set"][0]
      assoc["association_id"].should eq("vpc-cidr-assoc-0")
      assoc["cidr_block_state"]["state"].should eq("associated")
    end

    it "makes the two per-VPC DescribeVpcAttribute calls" do
      attributes = [] of String
      handler = ->(region : String, body : String) do
        params = URI::Params.parse(body)
        if params["Action"] == "DescribeVpcAttribute"
          attributes << params["Attribute"]
          attribute_response(params["Attribute"], "true")
        else
          DESCRIBE_ONE
        end
      end
      run_module({"region" => "us-east-1"}, handler)
      attributes.sort.should eq(["enableDnsHostnames", "enableDnsSupport"])
    end

    it "returns an empty list when no VPCs match" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_NONE })
      result["vpcs"].as_a.should be_empty
    end

    it "sends VpcId.N and Filter.N.Name/Value.M wire params" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body if URI::Params.parse(body)["Action"] == "DescribeVpcs"
        DESCRIBE_NONE
      end
      run_module({
        "region"  => "us-east-1",
        "vpc_ids" => %(["vpc-1234", "vpc-5678"]),
        "filters" => %({"is-default": "true"}),
      }, handler)

      params = URI::Params.parse(bodies.first.not_nil!)
      params.fetch_all("VpcId.1").should eq(["vpc-1234"])
      params.fetch_all("VpcId.2").should eq(["vpc-5678"])
      params.fetch_all("Filter.1.Name").should eq(["is-default"])
      params.fetch_all("Filter.1.Value.1").should eq(["true"])
    end

    it "fails with the API error message when the describe call errors" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { raise Krikri::PluginHelpers::Ec2Api::Error.new("UnauthorizedOperation: fake") })
      result["failed"].should eq(true)
      result["msg"].should eq("UnauthorizedOperation: fake")
    end
  end
end
