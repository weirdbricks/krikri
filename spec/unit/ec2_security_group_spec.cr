require "../spec_helper"
require "json"
require "../../src/krikri/plugin_helpers/ec2_api"
require "../../src/krikri/plugin_helpers/ec2_security_group"

# Decision-logic specs for amazon.aws.ec2_security_group. Everything below
# runs through the Ec2Api transport seam (no network): the describe result
# is canned XML fed straight to the parse/plan/diff helpers, and the
# full-module examples route the signed POSTs through a recording fake.
private DESCRIBE_ONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeSecurityGroupsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-1</requestId>
    <securityGroupInfo>
      <item>
        <groupId>sg-111</groupId>
        <groupName>web</groupName>
        <groupDescription>web group</groupDescription>
        <vpcId>vpc-1</vpcId>
        <ipPermissionsSet>
          <item>
            <ipProtocol>tcp</ipProtocol>
            <fromPort>22</fromPort>
            <toPort>22</toPort>
            <ipRanges>
              <item><cidrIp>10.0.0.0/8</cidrIp></item>
            </ipRanges>
          </item>
        </ipPermissionsSet>
        <ipPermissionsEgressSet>
          <item>
            <ipProtocol>-1</ipProtocol>
            <ipRanges>
              <item><cidrIp>0.0.0.0/0</cidrIp></item>
            </ipRanges>
          </item>
        </ipPermissionsEgressSet>
        <tagSet>
          <item><key>env</key><value>prod</value></item>
        </tagSet>
      </item>
    </securityGroupInfo>
  </DescribeSecurityGroupsResponse>
XML

private DESCRIBE_NONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeSecurityGroupsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-2</requestId>
    <securityGroupInfo/>
  </DescribeSecurityGroupsResponse>
XML

private def parse(xml : String)
  Krikri::PluginHelpers::Ec2SecurityGroup.parse_security_groups(XML.parse(xml).root.not_nil!)
end

private def run_module(params : Hash(String, String), handler : Proc(String, String, String)) : JSON::Any
  Krikri::PluginHelpers::Ec2Api.transport = handler
  begin
    result = Krikri::PluginHelpers::Ec2SecurityGroup.run(params)
    JSON.parse(result.to_json)
  ensure
    Krikri::PluginHelpers::Ec2Api.transport = nil
  end
end

describe Krikri::PluginHelpers::Ec2SecurityGroup do
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

  describe ".parse_security_groups" do
    it "reads group fields, rules, and tags" do
      groups = parse(DESCRIBE_ONE)
      groups.size.should eq(1)
      sg = groups[0]
      sg.group_id.should eq("sg-111")
      sg.group_name.should eq("web")
      sg.description.should eq("web group")
      sg.vpc_id.should eq("vpc-1")
      sg.tags.should eq({"env" => "prod"})

      sg.ingress.size.should eq(1)
      sg.ingress[0].proto.should eq("tcp")
      sg.ingress[0].from_port.should eq("22")
      sg.ingress[0].to_port.should eq("22")
      sg.ingress[0].cidr_ips.should eq(["10.0.0.0/8"])

      sg.egress.size.should eq(1)
      sg.egress[0].proto.should eq("-1")
      sg.egress[0].from_port.should be_nil
      sg.egress[0].cidr_ips.should eq(["0.0.0.0/0"])
    end

    it "returns an empty list for an empty set" do
      parse(DESCRIBE_NONE).should eq([] of Krikri::PluginHelpers::Ec2SecurityGroup::SecurityGroup)
    end
  end

  describe ".parse_rules" do
    it "normalizes proto 'all' and defaults a missing source to 0.0.0.0/0" do
      rules = Krikri::PluginHelpers::Ec2SecurityGroup.parse_rules(%([{"proto": "all", "from_port": 1}]))
      rules.size.should eq(1)
      rules[0].proto.should eq("-1")
      rules[0].to_port.should eq("1")
      rules[0].cidr_ips.should eq(["0.0.0.0/0"])
    end

    it "is empty for missing or malformed input" do
      Krikri::PluginHelpers::Ec2SecurityGroup.parse_rules(nil).should be_empty
      Krikri::PluginHelpers::Ec2SecurityGroup.parse_rules("not json").should be_empty
    end
  end

  describe ".diff_rules" do
    tcp22 = Krikri::PluginHelpers::Ec2SecurityGroup::Rule.new("tcp", "22", "22", ["0.0.0.0/0"], [] of String, [] of String, [] of String, [] of String)
    tcp443 = Krikri::PluginHelpers::Ec2SecurityGroup::Rule.new("tcp", "443", "443", ["0.0.0.0/0"], [] of String, [] of String, [] of String, [] of String)

    it "authorizes desired rules that are missing" do
      diff = Krikri::PluginHelpers::Ec2SecurityGroup.diff_rules([tcp443], [tcp22], true)
      diff.authorize.should eq([tcp443])
      diff.revoke.should eq([tcp22])
    end

    it "skips revocation when purge is false" do
      diff = Krikri::PluginHelpers::Ec2SecurityGroup.diff_rules([tcp443], [tcp22], false)
      diff.authorize.should eq([tcp443])
      diff.revoke.should be_empty
    end

    it "is a no-op when desired matches existing" do
      diff = Krikri::PluginHelpers::Ec2SecurityGroup.diff_rules([tcp22], [tcp22], true)
      diff.authorize.should be_empty
      diff.revoke.should be_empty
    end
  end

  describe ".plan_present" do
    existing = parse(DESCRIBE_ONE)[0]

    it "creates the group plus authorize calls when none exists" do
      plan = Krikri::PluginHelpers::Ec2SecurityGroup.plan_present("web", "d", nil, existing.ingress, existing.egress, true, true, {} of String => String, [] of Krikri::PluginHelpers::Ec2SecurityGroup::SecurityGroup)
      plan.changed.should be_true
      plan.steps.map(&.action).should eq(["CreateSecurityGroup", "AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress"])
      plan.steps[0].params.should contain({"GroupName", "web"})
      plan.steps[0].params.should contain({"GroupDescription", "d"})
    end

    it "is a no-op when the group already matches" do
      plan = Krikri::PluginHelpers::Ec2SecurityGroup.plan_present("web", "web group", "vpc-1", existing.ingress, existing.egress, true, true, {"env" => "prod"}, [existing])
      plan.changed.should be_false
      plan.steps.should be_empty
      plan.group_id.should eq("sg-111")
    end

    it "authorizes and revokes only the rule diff" do
      tcp80 = Krikri::PluginHelpers::Ec2SecurityGroup::Rule.new("tcp", "80", "80", ["0.0.0.0/0"], [] of String, [] of String, [] of String, [] of String)
      plan = Krikri::PluginHelpers::Ec2SecurityGroup.plan_present("web", "web group", "vpc-1", [tcp80], existing.egress, true, true, {} of String => String, [existing])
      plan.changed.should be_true
      plan.steps.map(&.action).should eq(["AuthorizeSecurityGroupIngress", "RevokeSecurityGroupIngress"])
      plan.steps[0].params.should contain({"IpPermissions.1.IpProtocol", "tcp"})
      plan.steps[1].params.should contain({"IpPermissions.1.IpRanges.1.CidrIp", "10.0.0.0/8"})
    end

    it "revokes the default allow-all egress rule when rules_egress is managed" do
      tcp443 = Krikri::PluginHelpers::Ec2SecurityGroup::Rule.new("tcp", "443", "443", ["0.0.0.0/0"], [] of String, [] of String, [] of String, [] of String)
      plan = Krikri::PluginHelpers::Ec2SecurityGroup.plan_present("web", "web group", "vpc-1", existing.ingress, [tcp443], true, true, {} of String => String, [existing])
      plan.changed.should be_true
      plan.steps.map(&.action).should eq(["AuthorizeSecurityGroupEgress", "RevokeSecurityGroupEgress"])
    end

    it "adds a CreateTags call for missing tags" do
      plan = Krikri::PluginHelpers::Ec2SecurityGroup.plan_present("web", "web group", "vpc-1", existing.ingress, existing.egress, true, true, {"env" => "staging"}, [existing])
      plan.changed.should be_true
      plan.steps.map(&.action).should eq(["CreateTags"])
      plan.steps[0].params.should contain({"ResourceId.1", "sg-111"})
      plan.steps[0].params.should contain({"Tag.1.Key", "env"})
      plan.steps[0].params.should contain({"Tag.1.Value", "staging"})
    end
  end

  describe ".plan_absent" do
    it "deletes an existing group by id" do
      existing = parse(DESCRIBE_ONE)
      plan = Krikri::PluginHelpers::Ec2SecurityGroup.plan_absent(existing, "web")
      plan.changed.should be_true
      plan.steps.map(&.action).should eq(["DeleteSecurityGroup"])
      plan.steps[0].params.should eq([{"GroupId", "sg-111"}])
    end

    it "is a no-op when absent" do
      plan = Krikri::PluginHelpers::Ec2SecurityGroup.plan_absent([] of Krikri::PluginHelpers::Ec2SecurityGroup::SecurityGroup, "web")
      plan.changed.should be_false
      plan.steps.should be_empty
    end
  end

  describe ".run" do
    it "creates a security group and returns the new group id" do
      result = run_module({"name" => "web", "description" => "web group", "state" => "present", "region" => "us-east-1"}, ->(region : String, body : String) do
        action = URI::Params.parse(body)["Action"]
        if action == "DescribeSecurityGroups"
          DESCRIBE_NONE
        else
          <<-XML
            <#{action}Response xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
              <return>true</return>
              <groupId>sg-new</groupId>
            </#{action}Response>
          XML
        end
      end)

      result["changed"].should eq(true)
      result["failed"].should eq(false)
      result["group_id"].should eq("sg-new")
      result["name"].should eq("web")
    end

    it "sends the group-name filter on the describe call" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        DESCRIBE_NONE
      end
      run_module({"name" => "web", "state" => "present", "region" => "us-east-1", "vpc_id" => "vpc-1"}, handler)
      describe_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "DescribeSecurityGroups" }.not_nil!
      describe_body.should contain("Filter.1.Name=group-name")
      describe_body.should contain("Filter.1.Value.1=web")
      describe_body.should contain("Filter.2.Name=vpc-id")
      describe_body.should contain("Filter.2.Value.1=vpc-1")
    end

    it "is a no-op when the group already matches" do
      result = run_module({"name" => "web", "description" => "web group", "state" => "present", "region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_ONE })
      result["changed"].should eq(false)
      result["group_id"].should eq("sg-111")
    end

    it "reports check mode without executing the plan" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        DESCRIBE_NONE
      end
      result = run_module({"name" => "web", "state" => "present", "region" => "us-east-1", "check_mode" => "true"}, handler)
      result["changed"].should eq(true)
      result["msg"].as_s.should contain("check mode")
      bodies.map { |b| URI::Params.parse(b)["Action"] }.uniq.should eq(["DescribeSecurityGroups"])
    end

    it "fails with the API error message when a call errors" do
      result = run_module({"name" => "web", "state" => "present", "region" => "us-east-1"}, ->(region : String, body : String) { raise Krikri::PluginHelpers::Ec2Api::Error.new("UnauthorizedOperation: fake") })
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
