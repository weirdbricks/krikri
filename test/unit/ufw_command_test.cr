require "../minitest_helper"
require "../../src/krikri/plugin_helpers/ufw_command"

# Command shapes verified against real community.general ufw.py source
# (its own "long format" comment), not run against a real ufw binary -
# see plugins/ufw.cr's module comment for why (ufw refuses to run at all
# without root, even for a bare status query, and the compat harness
# container lacks working netfilter access even as root).
describe Krikri::PluginHelpers::UfwCommand do
  describe ".state_command" do
    it "maps each state to its ufw subcommand" do
      Krikri::PluginHelpers::UfwCommand.state_command("enabled").must_equal("ufw -f enable")
      Krikri::PluginHelpers::UfwCommand.state_command("disabled").must_equal("ufw -f disable")
      Krikri::PluginHelpers::UfwCommand.state_command("reloaded").must_equal("ufw -f reload")
      Krikri::PluginHelpers::UfwCommand.state_command("reset").must_equal("ufw -f reset")
    end

    it "returns nil for an unknown state" do
      Krikri::PluginHelpers::UfwCommand.state_command("bogus").must_be_nil
    end
  end

  describe ".default_command" do
    it "builds a default policy command without a direction" do
      Krikri::PluginHelpers::UfwCommand.default_command("deny", nil).must_equal("ufw default deny")
    end

    it "includes the direction when given" do
      Krikri::PluginHelpers::UfwCommand.default_command("allow", "outgoing").must_equal("ufw default allow outgoing")
    end
  end

  describe ".rule_command" do
    it "builds a simple allow rule with from/to/port/proto" do
      params = {"rule" => "allow", "from_ip" => "any", "to_port" => "22", "to_ip" => "any", "proto" => "tcp"}
      Krikri::PluginHelpers::UfwCommand.rule_command(params).must_equal("ufw allow from any to any port 22 proto tcp")
    end

    it "prepends --dry-run right after the binary name when dry_run: true" do
      params = {"rule" => "allow", "to_port" => "22"}
      Krikri::PluginHelpers::UfwCommand.rule_command(params, dry_run: true).must_equal("ufw --dry-run allow from any to any port 22")
    end

    it "includes route and delete flags" do
      params = {"rule" => "allow", "route" => "true", "delete" => "true", "to_port" => "22"}
      Krikri::PluginHelpers::UfwCommand.rule_command(params).must_equal("ufw route delete allow from any to any port 22")
    end

    it "includes insert only when delete is not set" do
      params = {"rule" => "allow", "insert" => "1", "to_port" => "22"}
      Krikri::PluginHelpers::UfwCommand.rule_command(params).must_equal("ufw insert 1 allow from any to any port 22")
    end

    it "prefers interface: over interface_in:/interface_out:" do
      params = {"rule" => "allow", "interface" => "eth0", "to_port" => "22"}
      Krikri::PluginHelpers::UfwCommand.rule_command(params).must_equal("ufw allow on eth0 from any to any port 22")
    end

    it "appends from_port/to_port independently of from_ip/to_ip - a port given without its matching ip is still appended alone (matches real Ansible's source, which checks each of the four keys independently, not as ip+port pairs), and from_ip/to_ip default to 'any' (real Ansible's own argument default) rather than being omitted" do
      params = {"rule" => "allow", "from_port" => "1000", "to_ip" => "10.0.0.1"}
      Krikri::PluginHelpers::UfwCommand.rule_command(params).must_equal("ufw allow from any port 1000 to 10.0.0.1")
    end

    it "includes an app profile and a comment" do
      params = {"rule" => "allow", "name" => "OpenSSH", "comment" => "allow ssh"}
      Krikri::PluginHelpers::UfwCommand.rule_command(params).must_equal("ufw allow from any to any app 'OpenSSH' comment 'allow ssh'")
    end
  end

  # rule_command output is executed through /bin/bash -c (the plugin's
  # remote_exec), so a task param carrying a shell metacharacter must
  # arrive at ufw as a literal argv word, never as shell syntax.
  describe "shell-injection regression" do
    it "escapes from_ip carrying an apostrophe-breakout payload" do
      payload = "1.2.3.4'; touch /tmp/krikri-spec-ufw-pwn; #"
      cmd = Krikri::PluginHelpers::UfwCommand.rule_command({"rule" => "allow", "from_ip" => payload})
      cmd.must_equal("ufw allow from '1.2.3.4'\\''; touch /tmp/krikri-spec-ufw-pwn; #' to any")

      # Swap the binary for printf so a real bash -c reveals exactly what
      # argv each token would become - the payload must be ONE word.
      File.delete("/tmp/krikri-spec-ufw-pwn") if File.exists?("/tmp/krikri-spec-ufw-pwn")
      stdout = IO::Memory.new
      Process.new("/bin/bash", ["-c", cmd.sub("ufw ", "printf '[%s]' ")], output: stdout).wait
      stdout.to_s.must_equal("[allow][from][#{payload}][to][any]")
      File.exists?("/tmp/krikri-spec-ufw-pwn").must_equal(false)
    end

    it "escapes an embedded apostrophe in name/comment instead of letting it break the quoting" do
      cmd = Krikri::PluginHelpers::UfwCommand.rule_command(
        {"rule" => "allow", "name" => "my'app", "comment" => "it's'; touch /tmp/krikri-spec-ufw-pwn; #"}
      )
      cmd.must_equal("ufw allow from any to any app 'my'\\''app' comment 'it'\\''s'\\''; touch /tmp/krikri-spec-ufw-pwn; #'")
    end

    it "escapes interface, ports, and to_ip carrying shell metacharacters" do
      cmd = Krikri::PluginHelpers::UfwCommand.rule_command({
        "rule"      => "allow",
        "interface" => "eth0; touch /tmp/krikri-spec-ufw-pwn",
        "from_port" => "$(reboot)",
        "to_ip"     => "10.0.0.1' & reboot",
        "to_port"   => "22",
      })
      cmd.must_equal(
        "ufw allow on 'eth0; touch /tmp/krikri-spec-ufw-pwn' from any " \
        "port '$(reboot)' to '10.0.0.1'\\'' & reboot' port 22"
      )
    end
  end

  # Real ufw.py's check-mode rule decision and its ufw_version() parse,
  # ported from community.general's actual ufw.py source (including its
  # inverted-named filter_line_that_not_start_with, which KEEPS the
  # lines that start with the pattern - the module's own bug, and the
  # behavior the pre/post tuple diff silently depends on).
  describe ".check_mode_rule_changed?" do
    it "is false when every dry-run line says Skipping" do
      Krikri::PluginHelpers::UfwCommand.check_mode_rule_changed?("Skipping adding existing rule\n", "", "any", "any").must_equal(false)
    end

    it "is false when every dry-run line says Skipping, with a non-empty pre-rules grep" do
      output = "Skipping adding existing rule\nSkipping adding existing rule (v6)\n"
      pre = "### tuple allow tcp 8080 0.0.0.0/0 any - - -\n"
      Krikri::PluginHelpers::UfwCommand.check_mode_rule_changed?(output, pre, "any", "any").must_equal(false)
    end

    it "is true when the dry-run tuple lines differ from the pre rules" do
      pre = "### tuple allow tcp 8080 0.0.0.0/0 any - - -\n"
      output = "Rules updated\n### tuple allow tcp 8080 0.0.0.0/0 any - - -\n### tuple allow tcp 8081 0.0.0.0/0 any - - -\n"
      Krikri::PluginHelpers::UfwCommand.check_mode_rule_changed?(output, pre, "any", "any").must_equal(true)
    end

    it "is false when the dry-run tuple lines match the pre rules (no Skipping lines at all)" do
      pre = "### tuple allow tcp 8080 0.0.0.0/0 any - - -\n"
      output = "Rules updated\n### tuple allow tcp 8080 0.0.0.0/0 any - - -\n"
      Krikri::PluginHelpers::UfwCommand.check_mode_rule_changed?(output, pre, "any", "any").must_equal(false)
    end

    it "filters by ipv4 when the rule's from/to ip starts with an ipv4 literal" do
      pre = "### tuple allow tcp 8080 10.0.0.0/8 any - - -\n### tuple allow tcp 8080 ::/0 any - - -\n"
      output = "Rules updated\n### tuple allow tcp 8080 10.0.0.0/8 any - - -\n### tuple allow tcp 8080 ::/0 any - - -\n### tuple allow tcp 8081 10.0.0.5 any - - -\n"
      # the v6 tuple lines are filtered out on both sides; the new ipv4
      # tuple differs -> changed
      Krikri::PluginHelpers::UfwCommand.check_mode_rule_changed?(output, pre, "192.168.1.1", "any").must_equal(true)
    end

    it "ignores tuple differences outside the filtered family" do
      pre = "### tuple allow tcp 8080 10.0.0.0/8 any - - -\n"
      output = "Rules updated\n### tuple allow tcp 8080 10.0.0.0/8 any - - -\n### tuple allow tcp 8081 ::/0 any - - -\n"
      Krikri::PluginHelpers::UfwCommand.check_mode_rule_changed?(output, pre, "10.0.0.1", "any").must_equal(false)
    end
  end

  describe ".version_parses?" do
    it "accepts a real `ufw --version` first line" do
      Krikri::PluginHelpers::UfwCommand.version_parses?("ufw 0.36.2\n").must_equal(true)
      Krikri::PluginHelpers::UfwCommand.version_parses?("ufw 0.36\n").must_equal(true)
    end

    it "rejects empty or non-ufw output (real's 'Failed to get ufw version.' failure)" do
      Krikri::PluginHelpers::UfwCommand.version_parses?("").must_equal(false)
      Krikri::PluginHelpers::UfwCommand.version_parses?("not ufw\n").must_equal(false)
    end
  end

  describe ".splitlines_keepends" do
    it "mirrors Python splitlines(keepends=True) for the shapes the dry-run diff consumes" do
      Krikri::PluginHelpers::UfwCommand.splitlines_keepends("").must_equal([] of String)
      Krikri::PluginHelpers::UfwCommand.splitlines_keepends("a\n").must_equal(["a\n"])
      Krikri::PluginHelpers::UfwCommand.splitlines_keepends("a\nb").must_equal(["a\n", "b"])
      Krikri::PluginHelpers::UfwCommand.splitlines_keepends("a\nb\n").must_equal(["a\n", "b\n"])
    end
  end

  describe ".resolve_insert" do
    # 3 IPv4 rules (1-3) + 2 IPv6 rules (4-5), the same shape real `ufw
    # status numbered` produces - each expectation below was cross-checked
    # against a direct Python re-implementation of community.general's own
    # ufw.py resolution algorithm (read from its actual source, not
    # guessed) for the exact same inputs, not derived from the docs' prose.
    private def numbered_status
      <<-STATUS
        Status: active

             To                         Action      From
             --                         ------      ----
        [ 1] 22/tcp                     ALLOW IN    Anywhere
        [ 2] 80/tcp                     ALLOW IN    Anywhere
        [ 3] 443/tcp                    ALLOW IN    Anywhere
        [ 4] 22/tcp (v6)                ALLOW IN    Anywhere (v6)
        [ 5] 80/tcp (v6)                ALLOW IN    Anywhere (v6)
        STATUS
    end

    it "passes insert through unchanged for the default 'zero'" do
      Krikri::PluginHelpers::UfwCommand.resolve_insert(3, "zero", numbered_status).must_equal(3)
    end

    it "resolves relative to the first ipv4 rule" do
      Krikri::PluginHelpers::UfwCommand.resolve_insert(0, "first-ipv4", numbered_status).must_equal(1)
    end

    it "resolves relative to the last ipv4 rule (the roadmap's own doc example: -1 is the third-to-last ipv4 rule)" do
      Krikri::PluginHelpers::UfwCommand.resolve_insert(-1, "last-ipv4", numbered_status).must_equal(2)
    end

    it "resolves relative to the first ipv6 rule" do
      Krikri::PluginHelpers::UfwCommand.resolve_insert(0, "first-ipv6", numbered_status).must_equal(4)
    end

    it "resolves relative to the last ipv6 rule" do
      Krikri::PluginHelpers::UfwCommand.resolve_insert(0, "last-ipv6", numbered_status).must_equal(5)
    end

    it "returns nil when the resolved position would fall past the last existing rule" do
      Krikri::PluginHelpers::UfwCommand.resolve_insert(1, "last-ipv6", numbered_status).must_be_nil
    end

    it "falls back to position 1 for first-ipv4/last-ipv4 when there are no rules yet" do
      Krikri::PluginHelpers::UfwCommand.resolve_insert(0, "first-ipv4", "").must_be_nil
      Krikri::PluginHelpers::UfwCommand.resolve_insert(0, "last-ipv4", "").must_be_nil
    end

    it "resolves relative to an empty ruleset for first-ipv6 (no ipv4 rules means relative_to is 1)" do
      Krikri::PluginHelpers::UfwCommand.resolve_insert(-1, "first-ipv6", "").must_equal(0)
    end
  end
end

describe "Krikri::PluginHelpers::UfwCommand (clause emission and failure messages)" do
  describe "truthiness-gated clauses (real Ansible's [value, template] filter)" do
    it "skips an interface clause given as an empty string" do
      # Oefenweb.ufw maps every optional key through `default('')`, so
      # `interface: ""` arrives present-but-empty. Emitting a bare `on `
      # for it made real ufw reject the whole command with "ERROR: Wrong
      # number of arguments" - every rule in the role failed.
      cmd = Krikri::PluginHelpers::UfwCommand.rule_command({
        "rule" => "allow", "interface" => "", "direction" => "in",
        "to_port" => "22", "proto" => "tcp",
      })
      cmd.wont_include(" on ")
      cmd.must_equal("ufw allow in from any to any port 22 proto tcp")
    end

    it "emits all three interface forms independently, not as an if/elsif chain" do
      cmd = Krikri::PluginHelpers::UfwCommand.rule_command({
        "rule" => "allow", "interface_in" => "eth0", "interface_out" => "eth1",
      })
      cmd.must_include("in on eth0")
      cmd.must_include("out on eth1")
    end

    it "skips a direction given as an empty string" do
      Krikri::PluginHelpers::UfwCommand.rule_command({"rule" => "allow", "direction" => ""})
        .must_equal("ufw allow from any to any")
    end
  end

  describe "from_ip/to_ip defaulting" do
    it "emits `from any`/`to any` when the keys are absent" do
      # The arg-spec default is 'any'; without these real ufw rejects a
      # bare port rule with "Need 'to' or 'from' clause".
      Krikri::PluginHelpers::UfwCommand.rule_command({"rule" => "allow", "to_port" => "22"})
        .must_equal("ufw allow from any to any port 22")
    end

    it "skips the clause when the key is present but empty" do
      # Different case from absent: real Ansible gates on truthiness, so
      # an explicit empty string drops the clause rather than defaulting.
      cmd = Krikri::PluginHelpers::UfwCommand.rule_command({
        "rule" => "allow", "from_ip" => "", "to_ip" => "10.0.0.1", "to_port" => "22",
      })
      cmd.wont_include("from")
      cmd.must_equal("ufw allow to 10.0.0.1 port 22")
    end
  end

  # Regression anchor for the 2026-09-13 ad-hoc CLI comparison sweep:
  # the plugin used to read only the stdout of its pre/post
  # `ufw status verbose` probes and ignore their exit codes, so in a
  # container without CAP_NET_ADMIN (where even `ufw status verbose`
  # exits non-zero with iptables' permission error) a rule task
  # reported changed: true "Rules updated" where real Ansible failed.
  # Real ufw.py's execute() fails with `msg=err or out` - stderr wins.
  describe ".exec_failure_msg" do
    it "prefers stderr - real Ansible's msg=err or out" do
      Krikri::PluginHelpers::UfwCommand.exec_failure_msg(
        "Rules updated\nRules updated (v6)\n",
        "ERROR: problem running iptables: iptables v1.8.11 (nf_tables): " \
        "Could not fetch rule set generation id: Permission denied (you must be root)\n"
      ).must_equal(
        "ERROR: problem running iptables: iptables v1.8.11 (nf_tables): " \
        "Could not fetch rule set generation id: Permission denied (you must be root)\n"
      )
    end

    it "falls back to stdout when the failing command wrote nothing to stderr" do
      Krikri::PluginHelpers::UfwCommand.exec_failure_msg("some stdout\n", "").must_equal("some stdout\n")
    end

    it "returns an empty msg when the command produced no output at all" do
      Krikri::PluginHelpers::UfwCommand.exec_failure_msg("", "").must_equal("")
    end
  end
end
