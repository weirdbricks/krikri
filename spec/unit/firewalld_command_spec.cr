require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/firewalld_command"

# Command shapes and quirks verified empirically against a real
# firewalld 2.1.1 install (firewall-offline-cmd) in a real container -
# see plugins/firewalld.cr's module comment. Not derived from
# ansible-doc, which documents the Ansible module's own parameters, not
# the underlying CLI tool's exact flag names/quirks.
describe CrystalPlay::PluginHelpers::FirewalldCommand do
  describe ".thing" do
    it "returns the one present thing param" do
      CrystalPlay::PluginHelpers::FirewalldCommand.thing({"service" => "http"}).should eq({"service", "http"})
    end

    it "returns nil when no thing param is present" do
      CrystalPlay::PluginHelpers::FirewalldCommand.thing({} of String => String).should be_nil
    end

    it "returns nil when more than one thing param is present (matches real Ansible's mutually_exclusive constraint)" do
      CrystalPlay::PluginHelpers::FirewalldCommand.thing({"service" => "http", "port" => "8080/tcp"}).should be_nil
    end
  end

  describe ".query_command" do
    it "builds a query for a simple value" do
      CrystalPlay::PluginHelpers::FirewalldCommand.query_command("public", "service", "http")
        .should eq("firewall-offline-cmd --zone=public --query-service='http'")
    end

    it "translates rich_rule to the rich-rule flag" do
      CrystalPlay::PluginHelpers::FirewalldCommand.query_command("public", "rich_rule", "rule accept")
        .should eq("firewall-offline-cmd --zone=public --query-rich-rule='rule accept'")
    end

    it "omits the value for masquerade" do
      CrystalPlay::PluginHelpers::FirewalldCommand.query_command("public", "masquerade", "yes")
        .should eq("firewall-offline-cmd --zone=public --query-masquerade")
    end
  end

  describe ".add_command" do
    it "builds a plain --add-<thing>= command" do
      CrystalPlay::PluginHelpers::FirewalldCommand.add_command("public", "port", "8080/tcp")
        .should eq("firewall-offline-cmd --zone=public --add-port='8080/tcp'")
    end
  end

  describe ".remove_command" do
    it "uses --remove-service-from-zone for service (real, confirmed quirk: plain --remove-service can't combine with --zone=)" do
      CrystalPlay::PluginHelpers::FirewalldCommand.remove_command("public", "service", "http")
        .should eq("firewall-offline-cmd --zone=public --remove-service-from-zone='http'")
    end

    it "uses the plain --remove-<thing>= form for port/rich_rule/source/masquerade" do
      CrystalPlay::PluginHelpers::FirewalldCommand.remove_command("public", "port", "8080/tcp")
        .should eq("firewall-offline-cmd --zone=public --remove-port='8080/tcp'")
      CrystalPlay::PluginHelpers::FirewalldCommand.remove_command("public", "masquerade", "yes")
        .should eq("firewall-offline-cmd --zone=public --remove-masquerade")
    end
  end

  it "single-quotes values so a rich_rule's embedded double quotes and spaces survive shell interpolation (regression: an unquoted value broke against a real firewall-offline-cmd)" do
    value = %(rule family="ipv4" source address="192.168.1.0/24" accept)
    cmd = CrystalPlay::PluginHelpers::FirewalldCommand.add_command("public", "rich_rule", value)
    cmd.should eq(%(firewall-offline-cmd --zone=public --add-rich-rule='#{value}'))
  end
end
