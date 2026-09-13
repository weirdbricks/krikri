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

    it "uses the real -m flag for an explicit match: param (not a typo'd -mat)" do
      # Real bug found benchmarking bitintheskud.ansible-role-ecs-agent's
      # `match: tcp` NAT redirect rule: this was "-mat" instead of "-m" -
      # GNU iptables' getopt_long_only parses a bare "-mat" as "-m" with
      # "at" glued on as its value, tries to load a nonexistent "at"
      # match extension, and errors on both -C and -A - so the rule was
      # never actually applied, yet silently reported as changed=true
      # every single run (apply_rule doesn't check remote_exec's exit
      # code), forever.
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "destination"      => "169.254.170.2",
        "protocol"         => "tcp",
        "match"            => "tcp",
        "destination_port" => "80",
        "jump"             => "REDIRECT",
        "to_ports"         => "51679",
      })
      rule.should eq([
        "-p", "tcp",
        "-d", "169.254.170.2",
        "-m", "tcp",
        "-j", "REDIRECT",
        "--destination-port", "80",
        "--to-ports", "51679",
      ])
    end

    it "negates individual match: items with ! like real Ansible's list append_param" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "match" => "tcp,!udp",
      })
      rule.should eq(["-m", "tcp", "!", "-m", "udp"])
    end

    it "adds --tcp-flags from the JSON-encoded tcp_flags dict" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "protocol"  => "tcp",
        "tcp_flags" => %({"flags": ["ALL"], "flags_set": ["ACK", "RST", "SYN", "FIN"]}),
        "jump"      => "DROP",
      })
      rule.should eq([
        "-p", "tcp",
        "--tcp-flags", "ALL", "ACK,RST,SYN,FIN",
        "-j", "DROP",
      ])
    end

    it "skips --tcp-flags unless both flags and flags_set are present (real Ansible)" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "tcp_flags" => %({"flags": ["ALL"]}),
        "jump"      => "DROP",
      })
      rule.should eq(["-j", "DROP"])
    end

    it "adds --gateway right after -j for jump: TEE" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "jump"    => "TEE",
        "gateway" => "192.0.2.1",
      })
      rule.should eq(["-j", "TEE", "--gateway", "192.0.2.1"])
    end

    it "adds --gateway for a lowercase jump: tee" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "jump"    => "tee",
        "gateway" => "192.0.2.1",
      })
      rule.should eq(["-j", "tee", "--gateway", "192.0.2.1"])
    end

    it "ignores gateway unless jump is TEE (real Ansible)" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "jump"    => "ACCEPT",
        "gateway" => "192.0.2.1",
      })
      rule.should eq(["-j", "ACCEPT"])
    end

    it "maps goto to -g after --to-source (real module ordering)" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "to_source" => "192.0.2.1",
        "goto"      => "OTHER_CHAIN",
      })
      rule.should eq(["--to-source", "192.0.2.1", "-g", "OTHER_CHAIN"])
    end

    it "maps set_counters to -c after -f" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "fragment"     => "1",
        "set_counters" => "10 20",
        "jump"         => "ACCEPT",
      })
      rule.should eq(["-j", "ACCEPT", "-f", "1", "-c", "10 20"])
    end

    it "adds --set-dscp and an implicit -j DSCP when jump is unset" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "set_dscp_mark" => "8",
        "protocol"      => "tcp",
      })
      rule.should eq(["-p", "tcp", "--set-dscp", "8", "-j", "DSCP"])
    end

    it "does not add an implicit -j DSCP when jump is already DSCP" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "jump"          => "DSCP",
        "set_dscp_mark" => "8",
      })
      rule.should eq(["-j", "DSCP", "--set-dscp", "8"])
    end

    it "adds --set-dscp-class with an implicit -j DSCP when jump is something else" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "jump"                => "ACCEPT",
        "set_dscp_mark_class" => "CS1",
      })
      rule.should eq(["-j", "ACCEPT", "--set-dscp-class", "CS1", "-j", "DSCP"])
    end

    it "adds -m iprange implicitly for src_range/dst_range" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "src_range" => "192.168.1.100-192.168.1.199",
        "dst_range" => "10.0.0.1-10.0.0.50",
        "jump"      => "ACCEPT",
      })
      rule.should eq([
        "-j", "ACCEPT",
        "-m", "iprange",
        "--src-range", "192.168.1.100-192.168.1.199",
        "--dst-range", "10.0.0.1-10.0.0.50",
      ])
    end

    it "does not duplicate -m iprange when match already includes it" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "match"     => "iprange",
        "src_range" => "192.168.1.100-192.168.1.199",
      })
      rule.should eq(["-m", "iprange", "--src-range", "192.168.1.100-192.168.1.199"])
    end

    it "adds --match-set with the implicit -m set" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "match_set"       => "admin_hosts",
        "match_set_flags" => "src",
        "jump"            => "ALLOW",
      })
      rule.should eq(["-j", "ALLOW", "-m", "set", "--match-set", "admin_hosts", "src"])
    end

    it "skips the implicit -m set when match already includes set" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "match"           => "set",
        "match_set"       => "admin_hosts",
        "match_set_flags" => "src,dst",
      })
      rule.should eq(["-m", "set", "--match-set", "admin_hosts", "src,dst"])
    end

    it "adds the implicit -m limit when limit or limit_burst is set" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "limit"       => "2/second",
        "limit_burst" => "20",
      })
      rule.should eq(["-m", "limit", "--limit", "2/second", "--limit-burst", "20"])
    end

    it "adds -m owner and --uid-owner/--gid-owner, with ! negation" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "uid_owner" => "!1000",
        "gid_owner" => "dequeued",
        "jump"      => "ACCEPT",
      })
      rule.should eq([
        "-j", "ACCEPT",
        "-m", "owner", "!", "--uid-owner", "1000",
        "-m", "owner", "--gid-owner", "dequeued",
      ])
    end

    it "appends an implicit -j REJECT when reject_with is set without a jump" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "protocol"    => "tcp",
        "reject_with" => "tcp-reset",
      })
      rule.should eq(["-p", "tcp", "-j", "REJECT", "--reject-with", "tcp-reset"])
    end

    it "keeps --state (not --ctstate) when match explicitly includes state" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "match"   => "state",
        "ctstate" => "ESTABLISHED,RELATED",
      })
      rule.should eq(["-m", "state", "--state", "ESTABLISHED,RELATED"])
    end

    it "does not treat a substring match name as the conntrack match (token equality)" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "match"   => "conntrack-x",
        "ctstate" => "NEW",
      })
      rule.should eq(["-m", "conntrack-x", "-m", "conntrack", "--ctstate", "NEW"])
    end

    it "emits both icmp flags for ip_version: both (real Ansible quirk)" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "ip_version" => "both",
        "icmp_type"  => "echo-request",
        "jump"       => "DROP",
      })
      rule.should eq(["-j", "DROP", "--icmp-type", "--icmpv6-type", "echo-request"])
    end

    it "uses --icmpv6-type for ip_version: ipv6" do
      rule = Krikri::PluginHelpers::IptablesCommand.construct_rule({
        "ip_version" => "ipv6",
        "icmp_type"  => "echo-request",
      })
      rule.should eq(["--icmpv6-type", "echo-request"])
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

  describe ".push_arguments" do
    it "frames a -C check like real Ansible's push_arguments" do
      cmd = Krikri::PluginHelpers::IptablesCommand.push_arguments(
        "iptables", "-C", "INPUT", "filter",
        rule: ["-p", "tcp", "-j", "ACCEPT"],
        wait: "5"
      )
      cmd.should eq("iptables -t filter -C INPUT -w 5 -p tcp -j ACCEPT")
    end

    it "inserts the rule_num position only on -I" do
      insert = Krikri::PluginHelpers::IptablesCommand.push_arguments(
        "iptables", "-I", "INPUT", "filter",
        rule: ["-j", "ACCEPT"], rule_num: "5", wait: "5"
      )
      insert.should eq("iptables -t filter -I INPUT 5 -w 5 -j ACCEPT")

      check = Krikri::PluginHelpers::IptablesCommand.push_arguments(
        "iptables", "-C", "INPUT", "filter",
        rule: ["-j", "ACCEPT"], rule_num: "5", wait: "5"
      )
      check.should eq("iptables -t filter -C INPUT -w 5 -j ACCEPT")
    end

    it "appends --numeric only when the -L call site asks for it" do
      cmd = Krikri::PluginHelpers::IptablesCommand.push_arguments(
        "iptables", "-L", "INPUT", "filter", numeric: true
      )
      cmd.should eq("iptables -t filter -L INPUT --numeric")
    end

    it "omits -w and the chain when unset" do
      cmd = Krikri::PluginHelpers::IptablesCommand.push_arguments("iptables", "-F", nil, "nat")
      cmd.should eq("iptables -t nat -F")
    end
  end

  describe ".validate" do
    base = {"chain" => "INPUT"} of String => String

    it "passes a plain chain task" do
      Krikri::PluginHelpers::IptablesCommand.validate(base).should be_nil
    end

    it "fails set_dscp_mark + set_dscp_mark_class as mutually exclusive" do
      err = Krikri::PluginHelpers::IptablesCommand.validate({
        "chain"               => "OUTPUT",
        "jump"                => "DSCP",
        "set_dscp_mark"       => "8",
        "set_dscp_mark_class" => "CS1",
      })
      err.should eq("parameters are mutually exclusive: set_dscp_mark|set_dscp_mark_class")
    end

    it "fails an explicitly passed flush together with policy as mutually exclusive" do
      err = Krikri::PluginHelpers::IptablesCommand.validate({
        "chain"  => "INPUT",
        "flush"  => "true",
        "policy" => "DROP",
      })
      err.should eq("parameters are mutually exclusive: flush|policy")
    end

    it "requires gateway when jump is TEE" do
      err = Krikri::PluginHelpers::IptablesCommand.validate({
        "chain" => "PREROUTING",
        "jump"  => "TEE",
      })
      err.should eq("jump is TEE but all of the following are missing: gateway")
    end

    it "requires gateway when jump is tee (lowercase)" do
      err = Krikri::PluginHelpers::IptablesCommand.validate({
        "chain" => "PREROUTING",
        "jump"  => "tee",
      })
      err.should eq("jump is tee but all of the following are missing: gateway")
    end

    it "passes gateway when jump is TEE and gateway is set" do
      Krikri::PluginHelpers::IptablesCommand.validate({
        "chain"   => "PREROUTING",
        "jump"    => "TEE",
        "gateway" => "192.0.2.1",
      }).should be_nil
    end

    it "requires chain whenever flush is not truthy (the real default-False required_if)" do
      err = Krikri::PluginHelpers::IptablesCommand.validate({} of String => String)
      err.should eq("flush is False but all of the following are missing: chain")

      # Even a policy task without a chain fails this way in real Ansible.
      err = Krikri::PluginHelpers::IptablesCommand.validate({"policy" => "DROP"} of String => String)
      err.should eq("flush is False but all of the following are missing: chain")

      err = Krikri::PluginHelpers::IptablesCommand.validate({"flush" => "false"} of String => String)
      err.should eq("flush is False but all of the following are missing: chain")
    end

    it "does not require chain when flush is truthy" do
      Krikri::PluginHelpers::IptablesCommand.validate({"flush" => "true"} of String => String).should be_nil
    end

    it "requires jump for set_dscp_mark (required_by)" do
      err = Krikri::PluginHelpers::IptablesCommand.validate({
        "chain"         => "OUTPUT",
        "set_dscp_mark" => "8",
      })
      err.should eq("missing parameter(s) required by 'set_dscp_mark': jump")
    end

    it "requires jump for set_dscp_mark_class (required_by)" do
      err = Krikri::PluginHelpers::IptablesCommand.validate({
        "chain"               => "OUTPUT",
        "set_dscp_mark_class" => "CS1",
      })
      err.should eq("missing parameter(s) required by 'set_dscp_mark_class': jump")
    end

    it "passes set_dscp_mark with jump set" do
      Krikri::PluginHelpers::IptablesCommand.validate({
        "chain"         => "OUTPUT",
        "jump"          => "DSCP",
        "set_dscp_mark" => "8",
      }).should be_nil
    end

    it "checks mutually_exclusive before required_by (real Ansible's order)" do
      err = Krikri::PluginHelpers::IptablesCommand.validate({
        "chain"               => "OUTPUT",
        "set_dscp_mark"       => "8",
        "set_dscp_mark_class" => "CS1",
      })
      err.should eq("parameters are mutually exclusive: set_dscp_mark|set_dscp_mark_class")
    end
  end
end
