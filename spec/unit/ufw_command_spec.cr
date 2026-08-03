require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/ufw_command"

# Command shapes verified against real community.general ufw.py source
# (its own "long format" comment), not run against a real ufw binary -
# see plugins/ufw.cr's module comment for why (ufw refuses to run at all
# without root, even for a bare status query, and the compat harness
# container lacks working netfilter access even as root).
describe CrystalPlay::PluginHelpers::UfwCommand do
  describe ".state_command" do
    it "maps each state to its ufw subcommand" do
      CrystalPlay::PluginHelpers::UfwCommand.state_command("enabled").should eq("ufw --force enable")
      CrystalPlay::PluginHelpers::UfwCommand.state_command("disabled").should eq("ufw disable")
      CrystalPlay::PluginHelpers::UfwCommand.state_command("reloaded").should eq("ufw --force reload")
      CrystalPlay::PluginHelpers::UfwCommand.state_command("reset").should eq("ufw --force reset")
    end

    it "returns nil for an unknown state" do
      CrystalPlay::PluginHelpers::UfwCommand.state_command("bogus").should be_nil
    end
  end

  describe ".default_command" do
    it "builds a default policy command without a direction" do
      CrystalPlay::PluginHelpers::UfwCommand.default_command("deny", nil).should eq("ufw default deny")
    end

    it "includes the direction when given" do
      CrystalPlay::PluginHelpers::UfwCommand.default_command("allow", "outgoing").should eq("ufw default allow outgoing")
    end
  end

  describe ".rule_command" do
    it "builds a simple allow rule with from/to/port/proto" do
      params = {"rule" => "allow", "from_ip" => "any", "to_port" => "22", "to_ip" => "any", "proto" => "tcp"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw allow from any to any port 22 proto tcp")
    end

    it "prepends --dry-run right after the binary name when dry_run: true" do
      params = {"rule" => "allow", "to_port" => "22"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params, dry_run: true).should eq("ufw --dry-run allow port 22")
    end

    it "includes route and delete flags" do
      params = {"rule" => "allow", "route" => "true", "delete" => "true", "to_port" => "22"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw route delete allow port 22")
    end

    it "includes insert only when delete is not set" do
      params = {"rule" => "allow", "insert" => "1", "to_port" => "22"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw insert 1 allow port 22")
    end

    it "prefers interface: over interface_in:/interface_out:" do
      params = {"rule" => "allow", "interface" => "eth0", "to_port" => "22"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw allow on eth0 port 22")
    end

    it "appends from_port/to_port independently of from_ip/to_ip - a port given without its matching ip is still appended alone (matches real Ansible's source, which checks each of the four keys independently, not as ip+port pairs)" do
      params = {"rule" => "allow", "from_port" => "1000", "to_ip" => "10.0.0.1"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw allow port 1000 to 10.0.0.1")
    end

    it "includes an app profile and a comment" do
      params = {"rule" => "allow", "name" => "OpenSSH", "comment" => "allow ssh"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw allow app 'OpenSSH' comment 'allow ssh'")
    end
  end

  describe ".changed_from_output?" do
    it "is false when the output contains 'Skipping' (ufw's own no-op signal)" do
      CrystalPlay::PluginHelpers::UfwCommand.changed_from_output?("Skipping adding existing rule").should be_false
    end

    it "is true otherwise" do
      CrystalPlay::PluginHelpers::UfwCommand.changed_from_output?("Rule added").should be_true
    end
  end
end
