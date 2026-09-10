require "../spec_helper"
require "json"
require "../../src/krikri/plugin_helpers/ec2_api"
require "../../src/krikri/plugin_helpers/ec2_info"

# Read-only lookup specs for amazon.aws.ec2_ami_info. Everything runs
# through the Ec2Api transport seam (no network): canned
# DescribeImages/DescribeImageAttribute XML in, assertions on the shaped
# `images` result and the exact form bodies the module sends.
private DESCRIBE_TWO = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeImagesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-1</requestId>
    <imagesSet>
      <item>
        <imageId>ami-older</imageId>
        <imageLocation>123456789012/web-2024</imageLocation>
        <imageState>available</imageState>
        <imageOwnerId>123456789012</imageOwnerId>
        <isPublic>true</isPublic>
        <architecture>x86_64</architecture>
        <imageType>machine</imageType>
        <name>web-2024-01</name>
        <description>web image</description>
        <creationDate>2024-01-15T00:00:00.000Z</creationDate>
        <rootDeviceType>ebs</rootDeviceType>
        <rootDeviceName>/dev/xvda</rootDeviceName>
        <virtualizationType>hvm</virtualizationType>
        <hypervisor>xen</hypervisor>
        <sriovNetSupport>simple</sriovNetSupport>
        <enaSupport>true</enaSupport>
        <platformDetails>Linux/UNIX</platformDetails>
        <usageOperation>RunInstances</usageOperation>
        <tagSet>
          <item><key>Name</key><value>web</value></item>
        </tagSet>
        <blockDeviceMapping>
          <item>
            <deviceName>/dev/xvda</deviceName>
            <ebs>
              <volumeSize>8</volumeSize>
              <deleteOnTermination>true</deleteOnTermination>
              <volumeType>gp3</volumeType>
            </ebs>
          </item>
        </blockDeviceMapping>
      </item>
      <item>
        <imageId>ami-newer</imageId>
        <imageState>available</imageState>
        <imageOwnerId>123456789012</imageOwnerId>
        <isPublic>false</isPublic>
        <architecture>x86_64</architecture>
        <imageType>machine</imageType>
        <name>web-2024-02</name>
        <creationDate>2024-02-15T00:00:00.000Z</creationDate>
        <rootDeviceType>ebs</rootDeviceType>
        <rootDeviceName>/dev/xvda</rootDeviceName>
        <virtualizationType>hvm</virtualizationType>
        <hypervisor>xen</hypervisor>
      </item>
    </imagesSet>
  </DescribeImagesResponse>
XML

private DESCRIBE_NONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeImagesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-2</requestId>
    <imagesSet/>
  </DescribeImagesResponse>
XML

private LAUNCH_PERMISSION = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeImageAttributeResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-3</requestId>
    <imageId>ami-newer</imageId>
    <launchPermissionSet>
      <item><group>all</group></item>
      <item><userId>987654321098</userId></item>
    </launchPermissionSet>
  </DescribeImageAttributeResponse>
XML

private def run_module(params : Hash(String, String), handler : Proc(String, String, String)) : JSON::Any
  Krikri::PluginHelpers::Ec2Api.transport = handler
  begin
    result = Krikri::PluginHelpers::Ec2Info.run_images(params)
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

  describe ".run_images" do
    it "shapes images with the real module's field names" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_TWO })

      result["failed"].should eq(false)
      image = result["images"][0]
      image["image_id"].should eq("ami-older")
      image["state"].should eq("available")
      image["owner_id"].should eq("123456789012")
      image["is_public"].should eq(true)
      image["architecture"].should eq("x86_64")
      image["image_type"].should eq("machine")
      image["name"].should eq("web-2024-01")
      image["creation_date"].should eq("2024-01-15T00:00:00.000Z")
      image["root_device_type"].should eq("ebs")
      image["root_device_name"].should eq("/dev/xvda")
      image["virtualization_type"].should eq("hvm")
      image["hypervisor"].should eq("xen")
      image["sriov_net_support"].should eq("simple")
      image["ena_support"].should eq(true)
      image["platform_details"].should eq("Linux/UNIX")
      image["usage_operation"].should eq("RunInstances")
      image["tags"]["Name"].should eq("web")
    end

    it "shapes block device mappings" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_TWO })
      mapping = result["images"][0]["block_device_mappings"][0]
      mapping["device_name"].should eq("/dev/xvda")
      mapping["ebs"]["volume_size"].should eq("8")
      mapping["ebs"]["delete_on_termination"].should eq(true)
      mapping["ebs"]["volume_type"].should eq("gp3")
    end

    it "sorts images by creation_date" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_TWO })
      result["images"].as_a.map { |image| image["image_id"].as_s }.should eq(["ami-older", "ami-newer"])
    end

    it "returns an empty list when no images match" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_NONE })
      result["images"].as_a.should be_empty
    end

    it "fetches launch permissions when describe_image_attributes is set" do
      result = run_module({
        "region"                     => "us-east-1",
        "describe_image_attributes" => "true",
      }, ->(region : String, body : String) do
        URI::Params.parse(body)["Action"] == "DescribeImageAttribute" ? LAUNCH_PERMISSION : DESCRIBE_TWO
      end)

      result["failed"].should eq(false)
      permissions = result["images"][0]["launch_permissions"]
      permissions.as_a.size.should eq(2)
      permissions[0]["group"].should eq("all")
      permissions[1]["user_id"].should eq("987654321098")
    end

    it "omits launch permissions when the attribute call fails" do
      result = run_module({
        "region"                     => "us-east-1",
        "describe_image_attributes" => "true",
      }, ->(region : String, body : String) do
        URI::Params.parse(body)["Action"] == "DescribeImageAttribute" ? raise Krikri::PluginHelpers::Ec2Api::Error.new("AuthFailure: not permitted") : DESCRIBE_TWO
      end)

      result["failed"].should eq(false)
      result["images"][0]["launch_permissions"]?.should be_nil
      result["images"][1]["launch_permissions"]?.should be_nil
    end

    it "converts numeric owners to an owner-id filter and keeps self as an Owner param" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        DESCRIBE_NONE
      end
      run_module({
        "region"  => "us-east-1",
        "owners"  => %(["123456789012", "self", "amazon"]),
        "filters" => %({"owner-id": ["111122223333"]}),
      }, handler)

      params = URI::Params.parse(bodies.first.not_nil!)
      # numeric owner appended to the user's existing owner-id filter
      params.fetch_all("Filter.1.Name").should eq(["owner-id"])
      params.fetch_all("Filter.1.Value.1").should eq(["111122223333"])
      params.fetch_all("Filter.1.Value.2").should eq(["123456789012"])
      # non-numeric owner alias becomes its own filter
      params.fetch_all("Filter.2.Name").should eq(["owner-alias"])
      params.fetch_all("Filter.2.Value.1").should eq(["amazon"])
      # "self" stays an Owners param (not a valid owner-alias filter)
      params.fetch_all("Owner.1").should eq(["self"])
    end

    it "sends ImageId.N and ExecutableUser.N wire params" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        DESCRIBE_NONE
      end
      run_module({
        "region"           => "us-east-1",
        "image_ids"        => %(["ami-1234", "ami-5678"]),
        "executable_users" => %(["self"]),
      }, handler)

      params = URI::Params.parse(bodies.first.not_nil!)
      params.fetch_all("ImageId.1").should eq(["ami-1234"])
      params.fetch_all("ImageId.2").should eq(["ami-5678"])
      params.fetch_all("ExecutableUser.1").should eq(["self"])
    end

    it "fails with the API error message when a call errors" do
      result = run_module({"region" => "us-east-1"}, ->(region : String, body : String) { raise Krikri::PluginHelpers::Ec2Api::Error.new("UnauthorizedOperation: fake") })
      result["failed"].should eq(true)
      result["msg"].should eq("UnauthorizedOperation: fake")
    end
  end
end
