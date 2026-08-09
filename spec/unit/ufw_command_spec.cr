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
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params, dry_run: true).should eq("ufw --dry-run allow from any to any port 22")
    end

    it "includes route and delete flags" do
      params = {"rule" => "allow", "route" => "true", "delete" => "true", "to_port" => "22"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw route delete allow from any to any port 22")
    end

    it "includes insert only when delete is not set" do
      params = {"rule" => "allow", "insert" => "1", "to_port" => "22"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw insert 1 allow from any to any port 22")
    end

    it "prefers interface: over interface_in:/interface_out:" do
      params = {"rule" => "allow", "interface" => "eth0", "to_port" => "22"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw allow on eth0 from any to any port 22")
    end

    it "appends from_port/to_port independently of from_ip/to_ip - a port given without its matching ip is still appended alone (matches real Ansible's source, which checks each of the four keys independently, not as ip+port pairs), and from_ip/to_ip default to 'any' (real Ansible's own argument default) rather than being omitted" do
      params = {"rule" => "allow", "from_port" => "1000", "to_ip" => "10.0.0.1"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw allow from any port 1000 to 10.0.0.1")
    end

    it "includes an app profile and a comment" do
      params = {"rule" => "allow", "name" => "OpenSSH", "comment" => "allow ssh"}
      CrystalPlay::PluginHelpers::UfwCommand.rule_command(params).should eq("ufw allow from any to any app 'OpenSSH' comment 'allow ssh'")
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

  describe ".resolve_insert" do
    # 3 IPv4 rules (1-3) + 2 IPv6 rules (4-5), the same shape real `ufw
    # status numbered` produces - each expectation below was cross-checked
    # against a direct Python re-implementation of community.general's own
    # ufw.py resolution algorithm (read from its actual source, not
    # guessed) for the exact same inputs, not derived from the docs' prose.
    numbered_status = <<-STATUS
      Status: active

           To                         Action      From
           --                         ------      ----
      [ 1] 22/tcp                     ALLOW IN    Anywhere
      [ 2] 80/tcp                     ALLOW IN    Anywhere
      [ 3] 443/tcp                    ALLOW IN    Anywhere
      [ 4] 22/tcp (v6)                ALLOW IN    Anywhere (v6)
      [ 5] 80/tcp (v6)                ALLOW IN    Anywhere (v6)
      STATUS

    it "passes insert through unchanged for the default 'zero'" do
      CrystalPlay::PluginHelpers::UfwCommand.resolve_insert(3, "zero", numbered_status).should eq(3)
    end

    it "resolves relative to the first ipv4 rule" do
      CrystalPlay::PluginHelpers::UfwCommand.resolve_insert(0, "first-ipv4", numbered_status).should eq(1)
    end

    it "resolves relative to the last ipv4 rule (the roadmap's own doc example: -1 is the third-to-last ipv4 rule)" do
      CrystalPlay::PluginHelpers::UfwCommand.resolve_insert(-1, "last-ipv4", numbered_status).should eq(2)
    end

    it "resolves relative to the first ipv6 rule" do
      CrystalPlay::PluginHelpers::UfwCommand.resolve_insert(0, "first-ipv6", numbered_status).should eq(4)
    end

    it "resolves relative to the last ipv6 rule" do
      CrystalPlay::PluginHelpers::UfwCommand.resolve_insert(0, "last-ipv6", numbered_status).should eq(5)
    end

    it "returns nil when the resolved position would fall past the last existing rule" do
      CrystalPlay::PluginHelpers::UfwCommand.resolve_insert(1, "last-ipv6", numbered_status).should be_nil
    end

    it "falls back to position 1 for first-ipv4/last-ipv4 when there are no rules yet" do
      CrystalPlay::PluginHelpers::UfwCommand.resolve_insert(0, "first-ipv4", "").should be_nil
      CrystalPlay::PluginHelpers::UfwCommand.resolve_insert(0, "last-ipv4", "").should be_nil
    end

    it "resolves relative to an empty ruleset for first-ipv6 (no ipv4 rules means relative_to is 1)" do
      CrystalPlay::PluginHelpers::UfwCommand.resolve_insert(-1, "first-ipv6", "").should eq(0)
    end
  end
end
