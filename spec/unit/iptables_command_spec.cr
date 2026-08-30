require "../spec_helper"
require "../../src/krikri/plugin_helpers/iptables_command"

# Flag ordering verified against real Ansible's own ansible.builtin.iptables
# module (`construct_rule()` in ansible/modules/iptables.py) - see
# plugins/iptables.cr's own doc comment for why this is split out (real
# `iptables -C`/`-A` need CAP_NET_ADMIN, unavailable in the spec sandbox).
describe Krikri::PluginHelpers::IptablesCommand do
  describe ".construct_rule" do
    it "builds the robertdebock.natrouter NAT masquerade shape" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "out_interface" => "eth0",
        "source"        => "192.168.1.0/24",
        "destination"   => "0.0.0.0/0",
        "jump"          => "MASQUERADE",
        "protocol"      => "tcp",
        "comment"       => "Ansible NAT Masquerade",
      })

      rule.should eq([
        "-p", "tcp",
        "-s", "192.168.1.0/24",
        "-d", "0.0.0.0/0",
        "-j", "MASQUERADE",
        "-o", "eth0",
        "-m", "comment", "--comment", "'Ansible NAT Masquerade'",
      ])
    end

    it "puts -o after -j for out_interface (real module ordering)" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "out_interface" => "eth0",
        "jump"          => "MASQUERADE",
      })
      rule.should eq(["-j", "MASQUERADE", "-o", "eth0"])
    end

    it "negates a value prefixed with !" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "source" => "!192.168.1.0/24",
      })
      rule.should eq(["!", "-s", "192.168.1.0/24"])
    end

    it "adds -m multiport before --dports" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "destination_ports" => "80,443",
      })
      rule.should eq(["-m", "multiport", "--dports", "80,443"])
    end

    it "adds an implicit -m conntrack when ctstate is set without an explicit match" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "ctstate" => "ESTABLISHED,RELATED",
      })
      rule.should eq(["-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED"])
    end

    it "single-quotes the comment value" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "comment" => "Ansible NAT Masquerade",
      })
      rule.should eq(["-m", "comment", "--comment", "'Ansible NAT Masquerade'"])
    end

    it "returns an empty rule (chain-only operation) when no rule params are given" do
      Krikri::PluginHelpers::IptablesCommand.construct_rule({} of String => String).should eq([] of String)
    end
  end
end
