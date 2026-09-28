require "../minitest_helper"
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

describe "Krikri::PluginHelpers::Ec2Info (ec2_ami_info_test.cr)" do
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

  describe ".run_images" do
    it "shapes images with the real module's field names" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, _body : String) { DESCRIBE_TWO })

      expect(falsey?(result["failed"]?)).must_equal(true)
      image = result["images"][0]
      image["image_id"].must_equal("ami-older")
      image["state"].must_equal("available")
      image["owner_id"].must_equal("123456789012")
      image["public"].must_equal(true)
      image["architecture"].must_equal("x86_64")
      image["image_type"].must_equal("machine")
      image["name"].must_equal("web-2024-01")
      image["creation_date"].must_equal("2024-01-15T00:00:00.000Z")
      image["root_device_type"].must_equal("ebs")
      image["root_device_name"].must_equal("/dev/xvda")
      image["virtualization_type"].must_equal("hvm")
      image["hypervisor"].must_equal("xen")
      image["sriov_net_support"].must_equal("simple")
      image["ena_support"].must_equal(true)
      image["platform_details"].must_equal("Linux/UNIX")
      image["usage_operation"].must_equal("RunInstances")
      image["tags"]["Name"].must_equal("web")
    end

    it "shapes block device mappings" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, _body : String) { DESCRIBE_TWO })
      mapping = result["images"][0]["block_device_mappings"][0]
      mapping["device_name"].must_equal("/dev/xvda")
      mapping["ebs"]["volume_size"].must_equal(8)
      mapping["ebs"]["delete_on_termination"].must_equal(true)
      mapping["ebs"]["volume_type"].must_equal("gp3")
    end

    it "sorts images by creation_date" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, _body : String) { DESCRIBE_TWO })
      result["images"].as_a.map { |image| image["image_id"].as_s }.must_equal(["ami-older", "ami-newer"])
    end

    it "defaults tags to {} when the image has no tagSet, and carries no msg on success" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, _body : String) { DESCRIBE_TWO })
      result["msg"]?.must_be_nil
      result["images"][1]["tags"].as_h.must_be_empty
    end

    it "returns an empty list when no images match" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, _body : String) { DESCRIBE_NONE })
      result["images"].as_a.must_be_empty
    end

    it "fetches launch permissions when describe_image_attributes is set" do
      result = run_module({
        "region"                    => "us-east-1",
        "describe_image_attributes" => "true",
      }, ->(_region : String, body : String) do
        URI::Params.parse(body)["Action"] == "DescribeImageAttribute" ? LAUNCH_PERMISSION : DESCRIBE_TWO
      end)

      expect(falsey?(result["failed"]?)).must_equal(true)
      permissions = result["images"][0]["launch_permissions"]
      permissions.as_a.size.must_equal(2)
      permissions[0]["group"].must_equal("all")
      permissions[1]["user_id"].must_equal("987654321098")
    end

    it "omits launch permissions when the attribute call fails" do
      result = run_module({
        "region"                    => "us-east-1",
        "describe_image_attributes" => "true",
      }, ->(_region : String, body : String) do
        URI::Params.parse(body)["Action"] == "DescribeImageAttribute" ? raise Krikri::PluginHelpers::Ec2Api::Error.new("AuthFailure: not permitted") : DESCRIBE_TWO
      end)

      expect(falsey?(result["failed"]?)).must_equal(true)
      result["images"][0]["launch_permissions"]?.must_be_nil
      result["images"][1]["launch_permissions"]?.must_be_nil
    end

    it "converts numeric owners to an owner-id filter and keeps self as an Owner param" do
      bodies = [] of String
      handler = ->(_region : String, body : String) do
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
      params.fetch_all("Filter.1.Name").must_equal(["owner-id"])
      params.fetch_all("Filter.1.Value.1").must_equal(["111122223333"])
      params.fetch_all("Filter.1.Value.2").must_equal(["123456789012"])
      # non-numeric owner alias becomes its own filter
      params.fetch_all("Filter.2.Name").must_equal(["owner-alias"])
      params.fetch_all("Filter.2.Value.1").must_equal(["amazon"])
      # "self" stays an Owners param (not a valid owner-alias filter)
      params.fetch_all("Owner.1").must_equal(["self"])
    end

    it "sends ImageId.N and ExecutableUser.N wire params" do
      bodies = [] of String
      handler = ->(_region : String, body : String) do
        bodies << body
        DESCRIBE_NONE
      end
      run_module({
        "region"           => "us-east-1",
        "image_ids"        => %(["ami-1234", "ami-5678"]),
        "executable_users" => %(["self"]),
      }, handler)

      params = URI::Params.parse(bodies.first.not_nil!)
      params.fetch_all("ImageId.1").must_equal(["ami-1234"])
      params.fetch_all("ImageId.2").must_equal(["ami-5678"])
      params.fetch_all("ExecutableUser.1").must_equal(["self"])
    end

    it "fails with the API error message when a call errors" do
      result = run_module({"region" => "us-east-1"}, ->(_region : String, _body : String) { raise Krikri::PluginHelpers::Ec2Api::Error.new("UnauthorizedOperation: fake") })
      result["failed"].must_equal(true)
      result["msg"].must_equal("UnauthorizedOperation: fake")
    end
  end
end
