require "../spec_helper"
require "file_utils"
require "../../src/krikri/inventory_parser"

private ROOT = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "inventory_plugins_spec")

private def write(path : String, content : String)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
end

private def yaml_doc(content : String)
  YAML.parse(content)
end

private def sample_ec2_xml(instances : Array(String)) : String
  <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <reservationSet>
      <item>
        <ownerId>0123456789</ownerId>
        <instancesSet>
        #{instances.join("\n")}
        </instancesSet>
      </item>
    </reservationSet>
  </DescribeInstancesResponse>
  XML
end

private def ec2_instance_xml(
  instance_id : String,
  public_ip : String? = nil,
  private_ip : String? = nil,
  state : String = "running",
  tags : Hash(String, String) = {} of String => String,
)
  <<-XML
    <item>
      <instanceId>#{instance_id}</instanceId>
      <instanceType>t3.micro</instanceType>
      #{public_ip ? "<ipAddress>#{public_ip}</ipAddress>" : ""}
      #{private_ip ? "<privateIpAddress>#{private_ip}</privateIpAddress>" : ""}
      <privateDnsName>#{instance_id}.internal</privateDnsName>
      <instanceState><code>16</code><name>#{state}</name></instanceState>
      <placement><availabilityZone>us-east-1a</availabilityZone></placement>
      <tagSet>
        #{tags.map { |k, v| "<item><key>#{k}</key><value>#{v}</value></item>" }.join("\n")}
      </tagSet>
    </item>
  XML
end

private def inventory_with_host
  inventory = Krikri::Inventory.new
  host = Krikri::Host.new("web1")
  host.vars["ansible_host"] = JSON::Any.new("1.2.3.4")
  host.vars["instance_type"] = JSON::Any.new("t3.micro")
  host.vars["tags"] = JSON.parse({"Environment" => "prod", "Role" => "web"}.to_json)
  inventory.add_host(host)
  inventory.get_or_create_group("all").add_host(host)
  inventory
end

describe Krikri::InventoryPlugins do
  before_each do
    FileUtils.rm_rf(ROOT) if Dir.exists?(ROOT)
    Dir.mkdir_p(ROOT)
  end

  after_each do
    FileUtils.rm_rf(ROOT) if Dir.exists?(ROOT)
  end

  describe "plugin name detection" do
    it "detects plugin sources by the top-level plugin key" do
      doc = yaml_doc("plugin: amazon.aws.aws_ec2\nregions:\n  - us-east-1\n")
      Krikri::InventoryPlugins.plugin_name(doc).should eq("aws_ec2")
    end

    it "strips the collection prefix" do
      doc = yaml_doc("plugin: ansible.builtin.host_list\nhosts: web1,web2\n")
      Krikri::InventoryPlugins.plugin_name(doc).should eq("host_list")
    end

    it "returns nil for a normal YAML inventory" do
      doc = yaml_doc("all:\n  hosts:\n    web1: {}\n")
      Krikri::InventoryPlugins.plugin_name(doc).should be_nil
    end
  end

  describe "host_list plugin" do
    it "parses a comma-separated hosts string with range expansion" do
      doc = yaml_doc("plugin: host_list\nhosts: web1,web[01:03]\n")
      inventory = Krikri::InventoryPlugins.parse_plugin("fake.yml", doc, "host_list")
      inventory.hosts.keys.sort!.should eq(%w[web01 web02 web03 web1])
    end

    it "parses a YAML list of hosts" do
      doc = yaml_doc("plugin: host_list\nhosts:\n  - alpha\n  - beta\n")
      inventory = Krikri::InventoryPlugins.parse_plugin("fake.yml", doc, "host_list")
      inventory.hosts.keys.sort!.should eq(%w[alpha beta])
    end
  end

  describe "unknown plugin" do
    it "raises a helpful error" do
      doc = yaml_doc("plugin: azure.rm.azure_rm_compute\n")
      expect_raises(Exception, /not supported/) do
        Krikri::InventoryPlugins.parse_plugin("fake.yml", doc, "azure_rm_compute")
      end
    end
  end

  describe "aws_ec2 host building" do
    options = YAML.parse("plugin: aws_ec2\n")

    it "names hosts by public IP by default and sets ansible_host" do
      xml = sample_ec2_xml([ec2_instance_xml("i-123", public_ip: "1.2.3.4", private_ip: "10.0.0.5")])
      inventory = Krikri::Inventory.new
      Krikri::InventoryPlugins.build_aws_ec2_hosts(inventory, xml, options, "us-east-1")

      inventory.hosts.size.should eq(1)
      host = inventory.hosts["1.2.3.4"]
      host.vars["ansible_host"].as_s.should eq("1.2.3.4")
    end

    it "falls back to private IP, then instance-id" do
      xml = sample_ec2_xml([
        ec2_instance_xml("i-a", private_ip: "10.0.0.1"),
        ec2_instance_xml("i-b"),
      ])
      inventory = Krikri::Inventory.new
      Krikri::InventoryPlugins.build_aws_ec2_hosts(inventory, xml, options, "us-east-1")

      inventory.hosts.keys.should contain("10.0.0.1")
      inventory.hosts.keys.should contain("i-b")
    end

    it "skips terminated instances" do
      xml = sample_ec2_xml([
        ec2_instance_xml("i-live", public_ip: "1.2.3.4"),
        ec2_instance_xml("i-dead", public_ip: "1.2.3.5", state: "terminated"),
      ])
      inventory = Krikri::Inventory.new
      Krikri::InventoryPlugins.build_aws_ec2_hosts(inventory, xml, options, "us-east-1")

      inventory.hosts.keys.should eq(["1.2.3.4"])
    end

    it "honors the hostnames option including tag types" do
      tag_options = YAML.parse("plugin: aws_ec2\nhostnames:\n  - instance-id\n")
      xml = sample_ec2_xml([ec2_instance_xml("i-abc", public_ip: "1.2.3.4")])
      inventory = Krikri::Inventory.new
      Krikri::InventoryPlugins.build_aws_ec2_hosts(inventory, xml, tag_options, "us-east-1")
      inventory.hosts.keys.should eq(["i-abc"])

      tag_name_options = YAML.parse("plugin: aws_ec2\nhostnames:\n  - tag:Name\n")
      tagged_xml = sample_ec2_xml([ec2_instance_xml("i-abc", public_ip: "1.2.3.4", tags: {"Name" => "web-1"})])
      tagged_inventory = Krikri::Inventory.new
      Krikri::InventoryPlugins.build_aws_ec2_hosts(tagged_inventory, tagged_xml, tag_name_options, "us-east-1")
      tagged_inventory.hosts.keys.should eq(["web-1"])
    end

    it "exposes instance fields and tag vars" do
      xml = sample_ec2_xml([ec2_instance_xml("i-123", public_ip: "1.2.3.4", tags: {"Env" => "prod"})])
      inventory = Krikri::Inventory.new
      Krikri::InventoryPlugins.build_aws_ec2_hosts(inventory, xml, options, "us-east-1")

      host = inventory.hosts["1.2.3.4"]
      host.vars["instance_id"].as_s.should eq("i-123")
      host.vars["instance_type"].as_s.should eq("t3.micro")
      host.vars["region"].as_s.should eq("us-east-1")
      host.vars["tag.Env"].as_s.should eq("prod")
      host.vars["tag:Env"].as_s.should eq("prod")
      host.vars["tags"]["Env"].as_s.should eq("prod")
    end

    it "derives region from the availability zone" do
      xml = sample_ec2_xml([ec2_instance_xml("i-123", public_ip: "1.2.3.4")])
      inventory = Krikri::Inventory.new
      Krikri::InventoryPlugins.build_aws_ec2_hosts(inventory, xml, options, "us-east-1")
      # availabilityZone us-east-1a with region us-east-1 passed in
      inventory.hosts["1.2.3.4"].vars["region"].as_s.should eq("us-east-1")
    end
  end

  describe "constructed options" do
    it "creates keyed groups from a scalar key" do
      doc = yaml_doc("plugin: constructed\nkeyed_groups:\n  - key: instance_type\n    prefix: aws\n")
      inventory = Krikri::InventoryPlugins.apply_constructed_options(inventory_with_host, doc)
      inventory.groups.keys.should contain("aws_t3_micro")
      inventory.hosts_in_group("aws_t3_micro").map(&.name).should eq(["web1"])
    end

    it "creates one group per element for a list key" do
      inventory = inventory_with_host
      inventory.hosts["web1"].vars["ips"] = JSON.parse(["10.0.0.1", "10.0.0.2"].to_json)
      doc = yaml_doc("plugin: constructed\nkeyed_groups:\n  - key: ips\n    prefix: ip\n")
      inventory = Krikri::InventoryPlugins.apply_constructed_options(inventory, doc)
      inventory.groups.keys.should contain("ip_10_0_0_1")
      inventory.groups.keys.should contain("ip_10_0_0_2")
    end

    it "creates one group per key for a dict key (tags)" do
      doc = yaml_doc("plugin: constructed\nkeyed_groups:\n  - key: tags\n    prefix: tag\n")
      inventory = Krikri::InventoryPlugins.apply_constructed_options(inventory_with_host, doc)
      inventory.groups.keys.should contain("tag_Environment")
      inventory.groups.keys.should contain("tag_Role")
    end

    it "supports a custom separator, sanitizing group names" do
      doc = yaml_doc("plugin: constructed\nkeyed_groups:\n  - key: instance_type\n    prefix: aws\n    separator: '-'\n")
      inventory = Krikri::InventoryPlugins.apply_constructed_options(inventory_with_host, doc)
      # a dash is not a valid group-name character, so real Ansible
      # sanitizes it to an underscore
      inventory.groups.keys.should contain("aws_t3_micro")
    end

    it "strips the leading separator when leading_separator is false" do
      doc = yaml_doc("plugin: constructed\nleading_separator: false\nkeyed_groups:\n  - key: instance_type\n    separator: '-'\n")
      inventory = Krikri::InventoryPlugins.apply_constructed_options(inventory_with_host, doc)
      inventory.groups.keys.should contain("t3_micro")
    end

    it "applies compose expressions to host vars" do
      doc = yaml_doc("plugin: constructed\ncompose:\n  ansible_user: ansible_user | default('ec2-user')\n  dummy: instance_type\n")
      inventory = Krikri::InventoryPlugins.apply_constructed_options(inventory_with_host, doc)
      inventory.hosts["web1"].vars["dummy"].as_s.should eq("t3.micro")
      inventory.hosts["web1"].vars["ansible_user"].as_s.should eq("ec2-user")
    end

    it "adds hosts to groups via condition-style groups" do
      doc = yaml_doc("plugin: constructed\ngroups:\n  micros: instance_type == 't3.micro'\n  bigs: instance_type == 'm5.large'\n")
      inventory = Krikri::InventoryPlugins.apply_constructed_options(inventory_with_host, doc)
      inventory.hosts_in_group("micros").map(&.name).should eq(["web1"])
      inventory.hosts_in_group("bigs").should be_empty
    end

    it "filters hosts out of transformations but not the inventory" do
      doc = yaml_doc("plugin: constructed\nfilters:\n  - tag.Env=prod\n")
      inventory = inventory_with_host
      host2 = Krikri::Host.new("db1")
      inventory.add_host(host2)
      inventory.get_or_create_group("all").add_host(host2)

      result = Krikri::InventoryPlugins.apply_constructed_options(inventory, doc)
      result.hosts.size.should eq(2)
    end

    it "keeps hosts matching a bare key existence filter" do
      doc = yaml_doc("plugin: constructed\nfilters:\n  - instance_type\n")
      result = Krikri::InventoryPlugins.apply_constructed_options(inventory_with_host, doc)
      result.hosts.size.should eq(1)
    end
  end

  describe "directory parsing with a constructed source" do
    it "applies constructed options to hosts from sibling sources" do
      write("#{ROOT}/static.ini", "[web]\nweb1 ansible_host=1.2.3.4\n")
      write("#{ROOT}/transform.yml", "plugin: constructed\nkeyed_groups:\n  - key: ansible_host\n    prefix: host\n")

      inventory = Krikri::InventoryParser.parse(ROOT)
      inventory.hosts.keys.should eq(["web1"])
      inventory.groups.keys.should contain("host_1_2_3_4")
      inventory.hosts_in_group("host_1_2_3_4").map(&.name).should eq(["web1"])
    end

    it "does not treat normal YAML inventories as constructed sources" do
      write("#{ROOT}/plain.yml", "all:\n  hosts:\n    web2: {}\n")
      inventory = Krikri::InventoryParser.parse(ROOT)
      inventory.hosts.keys.should eq(["web2"])
      inventory.groups.keys.should_not contain("host_web2")
    end
  end

  describe "plugin files inside a directory" do
    it "parses a host_list plugin source alongside ini sources" do
      write("#{ROOT}/hosts.yml", "plugin: host_list\nhosts: pl1,pl2\n")
      write("#{ROOT}/static.ini", "[web]\nweb1\n")
      inventory = Krikri::InventoryParser.parse(ROOT)
      inventory.hosts.keys.sort!.should eq(%w[pl1 pl2 web1])
    end
  end
end
