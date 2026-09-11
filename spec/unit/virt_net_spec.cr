require "../spec_helper"
require "../../src/krikri/plugin_helpers/virsh_net"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# Unit-tests the virsh output parsing against real
# community.libvirt.virt_net's own behavior (read from its source) -
# the plugin's execution paths need a live libvirt daemon, the
# `virsh net-info`/net-dumpxml parsing doesn't.
describe Krikri::PluginHelpers::VirshNet do
  sample_info = "Name:           default
UUID:           828fcd0e-90ee-4a58-a52d-7f1b38a2af17
Active:         yes
Persistent:     yes
Autostart:      no
Bridge:         virbr0
"

  describe ".parse_net_info" do
    it "parses the yes/no fields and bridge" do
      info = Krikri::PluginHelpers::VirshNet.parse_net_info(sample_info)
      info[:active].should be_true
      info[:autostart].should be_false
      info[:persistent].should be_true
      info[:bridge].should eq("virbr0")
    end

    it "leaves a missing Bridge line as nil" do
      info = Krikri::PluginHelpers::VirshNet.parse_net_info("Name: x\nActive: no\n")
      info[:bridge].should be_nil
      info[:active].should be_false
    end
  end

  describe ".parse_forward_mode / .parse_domain / .parse_macaddress" do
    xml = "<network><name>default</name><forward mode='nat'/><domain name='example.lan'/><mac address='52:54:00:aa:bb:cc'/></network>"
    it "extracts the fact fields the real module xpath-scans" do
      Krikri::PluginHelpers::VirshNet.parse_forward_mode(xml).should eq("nat")
      Krikri::PluginHelpers::VirshNet.parse_domain(xml).should eq("example.lan")
      Krikri::PluginHelpers::VirshNet.parse_macaddress(xml).should eq("52:54:00:aa:bb:cc")
    end

    it "returns nil when the element is absent" do
      Krikri::PluginHelpers::VirshNet.parse_forward_mode("<network/>").should be_nil
      Krikri::PluginHelpers::VirshNet.parse_domain("<network/>").should be_nil
      Krikri::PluginHelpers::VirshNet.parse_macaddress("<network/>").should be_nil
    end
  end

  describe ".parse_dhcp_hosts" do
    it "extracts mac/name/ip from self-closing host entries" do
      xml = "<network><ip><dhcp><host mac='FC:C2:33:00:6c:3c' name='my_vm' ip='192.168.122.30'/></dhcp></ip></network>"
      hosts = Krikri::PluginHelpers::VirshNet.parse_dhcp_hosts(xml)
      hosts.size.should eq(1)
      hosts[0].mac.should eq("FC:C2:33:00:6c:3c")
      hosts[0].name.should eq("my_vm")
      hosts[0].ip.should eq("192.168.122.30")
    end
  end

  describe ".net_update_command" do
    it "maps a host entry to add-last ip-dhcp-host, live+config when active" do
      cmd = Krikri::PluginHelpers::VirshNet.net_update_command(
        "qemu:///system", "br_nat", "<host mac='FC:C2:33:00:6c:3c' name='my_vm' ip='192.168.122.30'/>", true
      )
      cmd.should eq(["virsh", "--connect", "qemu:///system", "net-update", "br_nat",
                     "add-last", "ip-dhcp-host", "<host mac='FC:C2:33:00:6c:3c' name='my_vm' ip='192.168.122.30'/>",
                     "--live", "--config"])
    end

    it "is config-only when the network is inactive" do
      cmd = Krikri::PluginHelpers::VirshNet.net_update_command("qemu:///system", "br_nat", "<host mac='x'/>", false)
      cmd.not_nil!.should_not contain("--live")
    end

    it "rejects non-host sections like the real module" do
      Krikri::PluginHelpers::VirshNet.net_update_command("qemu:///system", "br_nat", "<bridge/>", false).should be_nil
    end
  end

  describe ".virsh" do
    it "threads the connection URI before the subcommand" do
      Krikri::PluginHelpers::VirshNet.virsh("qemu:///system", "net-start", "br_nat")
        .should eq(["virsh", "--connect", "qemu:///system", "net-start", "br_nat"])
    end
  end
end

describe "virt_net registration" do
  it "resolves the bare and FQCN spellings onto the virt_net plugin" do
    Krikri::PlaybookParser.resolve_module_name("virt_net").should eq("virt_net")
    Krikri::PlaybookParser.resolve_module_name("community.libvirt.virt_net").should eq("virt_net")
    Krikri::PluginManager.simple_plugin_name("virt_net").should eq("virt_net")
  end
end
