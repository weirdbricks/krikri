require "../minitest_helper"
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

# A VPC the wire response carries no tagSet for at all (the real API
# omits it for untagged VPCs) - the Ansible module still returns tags: {}.
private DESCRIBE_NO_TAGS = <<-XML
<?xml version="1.0" encoding="UTF-8"?>
  <DescribeVpcsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-4</requestId>
    <vpcSet>
      <item>
        <vpcId>vpc-bare</vpcId>
        <cidrBlock>10.1.0.0/16</cidrBlock>
        <state>available</state>
        <isDefault>false</isDefault>
        <instanceTenancy>default</instanceTenancy>
        <dhcpOptionsId>dopt-1</dhcpOptionsId>
        <ownerId>123456789012</ownerId>
      </item>
    </vpcSet>
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

describe "Krikri::PluginHelpers::Ec2Info (ec2_vpc_net_info_test.cr)" do
  serial! # mutates process-global state (ENV / engine settings)

  before_each do
    @old_access = ENV["AWS_ACCESS_KEY_ID"]?
    @old_secret = ENV["AWS_SECRET_ACCESS_KEY"]?
    ENV["AWS_ACCESS_KEY_ID"] = "test-access"
    ENV["AWS_SECRET_ACCESS_KEY"] = "test-secret"
  end

  after_each do
    if @old_access
      ENV["AWS_ACCESS_KEY_ID"] = @old_access
    else
      ENV.delete("AWS_ACCESS_KEY_ID")
    end
    if @old_secret
      ENV["AWS_SECRET_ACCESS_KEY"] = @old_secret
    else
      ENV.delete("AWS_SECRET_ACCESS_KEY")
    end
  end

  describe ".run_vpcs" do
    it "shapes a VPC with the Ansible module's field names, DNS attributes included" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, body : String) do
        action = URI::Params.parse(body)["Action"]
        case action
        when "DescribeVpcs" then DESCRIBE_ONE
        when "DescribeVpcAttribute"
          attribute = URI::Params.parse(body)["Attribute"]
          attribute_response(attribute, attribute == "enableDnsSupport" ? "true" : "false")
        else
          raise "unexpected action #{action}"
        end
      end)

      expect(falsey?(result["failed"]?)).must_equal(true)
      vpc = result["vpcs"][0]
      vpc["id"].must_equal("vpc-1234")
      vpc["vpc_id"].must_equal("vpc-1234")
      vpc["cidr_block"].must_equal("10.0.0.0/16")
      vpc["state"].must_equal("available")
      vpc["is_default"].must_equal(true)
      vpc["instance_tenancy"].must_equal("default")
      vpc["dhcp_options_id"].must_equal("dopt-1")
      vpc["owner_id"].must_equal("123456789012")
      vpc["enable_dns_support"].must_equal(true)
      vpc["enable_dns_hostnames"].must_equal(false)
      vpc["tags"]["Name"].must_equal("main")
      assoc = vpc["cidr_block_association_set"][0]
      assoc["association_id"].must_equal("vpc-cidr-assoc-0")
      assoc["cidr_block_state"]["state"].must_equal("associated")
    end

    it "defaults tags to {} when the VPC has no tagSet, and carries no msg on success" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, body : String) do
        action = URI::Params.parse(body)["Action"]
        case action
        when "DescribeVpcs" then DESCRIBE_NO_TAGS
        when "DescribeVpcAttribute"
          attribute_response(URI::Params.parse(body)["Attribute"], "true")
        else
          raise "unexpected action #{action}"
        end
      end)
      expect(falsey?(result["failed"]?)).must_equal(true)
      result["msg"]?.must_be_nil
      result["vpcs"][0]["tags"].as_h.must_be_empty
    end

    it "makes the two per-VPC DescribeVpcAttribute calls" do
      attributes = [] of String
      handler = ->(_region : String, body : String) do
        params = URI::Params.parse(body)
        if params["Action"] == "DescribeVpcAttribute"
          attributes << params["Attribute"]
          attribute_response(params["Attribute"], "true")
        else
          DESCRIBE_ONE
        end
      end
      run_module({"region" => "us-east-1"}, handler)
      attributes.sort.must_equal(["enableDnsHostnames", "enableDnsSupport"])
    end

    it "returns an empty list when no VPCs match" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, _body : String) { DESCRIBE_NONE })
      result["vpcs"].as_a.must_be_empty
    end

    it "sends VpcId.N and Filter.N.Name/Value.M wire params" do
      bodies = [] of String
      handler = ->(_region : String, body : String) do
        bodies << body if URI::Params.parse(body)["Action"] == "DescribeVpcs"
        DESCRIBE_NONE
      end
      run_module({
        "region"  => "us-east-1",
        "vpc_ids" => %(["vpc-1234", "vpc-5678"]),
        "filters" => %({"is-default": "true"}),
      }, handler)

      params = URI::Params.parse(bodies.first.not_nil!)
      params.fetch_all("VpcId.1").must_equal(["vpc-1234"])
      params.fetch_all("VpcId.2").must_equal(["vpc-5678"])
      params.fetch_all("Filter.1.Name").must_equal(["is-default"])
      params.fetch_all("Filter.1.Value.1").must_equal(["true"])
    end

    it "fails with the API error message when the describe call errors" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, _body : String) { raise Krikri::PluginHelpers::Ec2Api::Error.new("UnauthorizedOperation: fake") })
      result["failed"].must_equal(true)
      result["msg"].must_equal("UnauthorizedOperation: fake")
    end
  end
end
