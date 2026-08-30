require "../spec_helper"
require "../../src/krikri/plugin_helpers/firewalld_command"

# Command shapes and quirks verified empirically against a real
# firewalld 2.1.1 install (firewall-offline-cmd) in a real container -
# see plugins/firewalld.cr's module comment. Not derived from
# ansible-doc, which documents the Ansible module's own parameters, not
# the underlying CLI tool's exact flag names/quirks.
describe Krikri::PluginHelpers::FirewalldCommand do
  describe ".thing" do
    it "returns the one present thing param" do
      Krikri::PluginHelpers::FirewalldCommand.thing({"service" => "http"}).should eq({"service", "http"})
    end

    it "returns nil when no thing param is present" do
      Krikri::PluginHelpers::FirewalldCommand.thing({} of String => String).should be_nil
    end

    it "returns nil when more than one thing param is present (matches real Ansible's mutually_exclusive constraint)" do
      Krikri::PluginHelpers::FirewalldCommand.thing({"service" => "http", "port" => "8080/tcp"}).should be_nil
    end
  end

  describe ".query_command" do
    it "builds a query for a simple value" do
      Krikri::PluginHelpers::FirewalldCommand.query_command("public", "service", "http")
        .should eq("firewall-offline-cmd --zone=public --query-service='http'")
    end

    it "translates rich_rule to the rich-rule flag" do
      Krikri::PluginHelpers::FirewalldCommand.query_command("public", "rich_rule", "rule accept")
        .should eq("firewall-offline-cmd --zone=public --query-rich-rule='rule accept'")
    end

    it "omits the value for masquerade" do
      Krikri::PluginHelpers::FirewalldCommand.query_command("public", "masquerade", "yes")
        .should eq("firewall-offline-cmd --zone=public --query-masquerade")
    end
  end

  describe ".add_command" do
    it "builds a plain --add-<thing>= command" do
      Krikri::PluginHelpers::FirewalldCommand.add_command("public", "port", "8080/tcp")
        .should eq("firewall-offline-cmd --zone=public --add-port='8080/tcp'")
    end
  end

  describe ".remove_command" do
    it "uses --remove-service-from-zone for service (real, confirmed quirk: plain --remove-service can't combine with --zone=)" do
      Krikri::PluginHelpers::FirewalldCommand.remove_command("public", "service", "http")
        .should eq("firewall-offline-cmd --zone=public --remove-service-from-zone='http'")
    end

    it "uses the plain --remove-<thing>= form for port/rich_rule/source/masquerade" do
      Krikri::PluginHelpers::FirewalldCommand.remove_command("public", "port", "8080/tcp")
        .should eq("firewall-offline-cmd --zone=public --remove-port='8080/tcp'")
      Krikri::PluginHelpers::FirewalldCommand.remove_command("public", "masquerade", "yes")
        .should eq("firewall-offline-cmd --zone=public --remove-masquerade")
    end
  end

  it "single-quotes values so a rich_rule's embedded double quotes and spaces survive shell interpolation (regression: an unquoted value broke against a real firewall-offline-cmd)" do
    value = %(rule family="ipv4" source address="192.168.1.0/24" accept)
    cmd = Krikri::PluginHelpers::FirewalldCommand.add_command("public", "rich_rule", value)
    cmd.should eq(%(firewall-offline-cmd --zone=public --add-rich-rule='#{value}'))
  end

  # Real bugs found via a proactive scope-cut audit: interface/
  # icmp_block/protocol/icmp_block_inversion/forward were entirely
  # unimplemented. Every command shape below was verified live against a
  # real `firewall-offline-cmd` (firewalld 2.3.1, installed fresh in a
  # throwaway Debian container specifically to check these - not
  # available on the regular dev machine, so not exercised by an
  # integration spec the way the pre-existing things are; this covers
  # the pure command-construction logic instead).
  describe "interface/icmp_block/protocol (plain value things)" do
    it "builds --add-interface=/--remove-interface=/--query-interface=" do
      Krikri::PluginHelpers::FirewalldCommand.add_command("public", "interface", "eth0")
        .should eq("firewall-offline-cmd --zone=public --add-interface='eth0'")
      Krikri::PluginHelpers::FirewalldCommand.remove_command("public", "interface", "eth0")
        .should eq("firewall-offline-cmd --zone=public --remove-interface='eth0'")
      Krikri::PluginHelpers::FirewalldCommand.query_command("public", "interface", "eth0")
        .should eq("firewall-offline-cmd --zone=public --query-interface='eth0'")
    end

    it "builds --add-icmp-block=/--remove-icmp-block=" do
      Krikri::PluginHelpers::FirewalldCommand.add_command("public", "icmp_block", "echo-request")
        .should eq("firewall-offline-cmd --zone=public --add-icmp-block='echo-request'")
      Krikri::PluginHelpers::FirewalldCommand.remove_command("public", "icmp_block", "echo-request")
        .should eq("firewall-offline-cmd --zone=public --remove-icmp-block='echo-request'")
    end

    it "builds --add-protocol=/--remove-protocol=" do
      Krikri::PluginHelpers::FirewalldCommand.add_command("public", "protocol", "ah")
        .should eq("firewall-offline-cmd --zone=public --add-protocol='ah'")
      Krikri::PluginHelpers::FirewalldCommand.remove_command("public", "protocol", "ah")
        .should eq("firewall-offline-cmd --zone=public --remove-protocol='ah'")
    end
  end

  describe "icmp_block_inversion/forward (no-value boolean things, same pattern as masquerade)" do
    it "builds --add-icmp-block-inversion/--remove-icmp-block-inversion with no value" do
      Krikri::PluginHelpers::FirewalldCommand.add_command("public", "icmp_block_inversion", "true")
        .should eq("firewall-offline-cmd --zone=public --add-icmp-block-inversion")
      Krikri::PluginHelpers::FirewalldCommand.remove_command("public", "icmp_block_inversion", "true")
        .should eq("firewall-offline-cmd --zone=public --remove-icmp-block-inversion")
    end

    it "builds --add-forward/--remove-forward with no value" do
      Krikri::PluginHelpers::FirewalldCommand.add_command("public", "forward", "true")
        .should eq("firewall-offline-cmd --zone=public --add-forward")
      Krikri::PluginHelpers::FirewalldCommand.remove_command("public", "forward", "true")
        .should eq("firewall-offline-cmd --zone=public --remove-forward")
    end
  end

  describe ".thing" do
    it "recognizes every new thing as the one selected param" do
      %w[interface icmp_block protocol icmp_block_inversion forward].each do |key|
        Krikri::PluginHelpers::FirewalldCommand.thing({key => "x"}).should eq({key, "x"})
      end
    end
  end

  # port_forward is structurally different from every other "thing" -
  # a dict, not a scalar - so it's not part of `.thing`/SUPPORTED_THINGS
  # at all; the plugin handles it as a separate case. Verified live
  # against a real `firewall-offline-cmd` (firewalld 1.3.3, Debian
  # bookworm container): `--add-forward-port=`/`--remove-forward-port=`/
  # `--query-forward-port=` are their own distinct flags taking this
  # compound value.
  describe ".port_forward_value" do
    it "builds the compound value with toaddr" do
      entry = JSON.parse(%({"port": 80, "proto": "tcp", "toport": 8080, "toaddr": "192.168.1.1"}))
      Krikri::PluginHelpers::FirewalldCommand.port_forward_value(entry)
        .should eq({value: "port=80:proto=tcp:toport=8080:toaddr=192.168.1.1", error: nil})
    end

    it "omits toaddr from the value when absent (matches real Ansible's own default of '')" do
      entry = JSON.parse(%({"port": 80, "proto": "tcp", "toport": 8080}))
      Krikri::PluginHelpers::FirewalldCommand.port_forward_value(entry)
        .should eq({value: "port=80:proto=tcp:toport=8080", error: nil})
    end

    it "errors on a missing port (checked first, matching real Ansible's own check order)" do
      entry = JSON.parse(%({"proto": "tcp", "toport": 8080}))
      Krikri::PluginHelpers::FirewalldCommand.port_forward_value(entry)
        .should eq({value: nil, error: "port must be specified for port forward"})
    end

    it "errors on a missing proto" do
      entry = JSON.parse(%({"port": 80, "toport": 8080}))
      Krikri::PluginHelpers::FirewalldCommand.port_forward_value(entry)
        .should eq({value: nil, error: "proto udp/tcp must be specified for port forward"})
    end

    it "errors on a missing toport" do
      entry = JSON.parse(%({"port": 80, "proto": "tcp"}))
      Krikri::PluginHelpers::FirewalldCommand.port_forward_value(entry)
        .should eq({value: nil, error: "toport must be specified for port forward"})
    end
  end

  describe ".forward_port_query_command/.forward_port_add_command/.forward_port_remove_command" do
    it "builds the three distinct forward-port commands" do
      Krikri::PluginHelpers::FirewalldCommand.forward_port_query_command("public", "port=80:proto=tcp:toport=8080")
        .should eq("firewall-offline-cmd --zone=public --query-forward-port='port=80:proto=tcp:toport=8080'")
      Krikri::PluginHelpers::FirewalldCommand.forward_port_add_command("public", "port=80:proto=tcp:toport=8080")
        .should eq("firewall-offline-cmd --zone=public --add-forward-port='port=80:proto=tcp:toport=8080'")
      Krikri::PluginHelpers::FirewalldCommand.forward_port_remove_command("public", "port=80:proto=tcp:toport=8080")
        .should eq("firewall-offline-cmd --zone=public --remove-forward-port='port=80:proto=tcp:toport=8080'")
    end
  end
end
