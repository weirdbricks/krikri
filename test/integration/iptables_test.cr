require "../minitest_helper"

# The iptables plugin shells out to the real binary for every operation
# (-C/-A/-D all need CAP_NET_ADMIN, unavailable in the spec sandbox), so
# only the argument-shape failures that real raises BEFORE touching the
# binary are spec'd here - which is exactly the class the kpg32 seed-32
# sweep turned up. Each expectation was live-verified against
# ansible-core 2.19.11 with the real binary reachable.
describe "iptables plugin (pre-execution argument failures)" do
  # Both are uncaught exceptions inside real's own construct_rule(): the
  # args dict's `rule=' '.join(construct_rule(module.params))` runs before
  # the module ever resolves the iptables binary, so a target without
  # iptables installed still reports these two verbatim.
  it "fails with real's join TypeError when tcp_flags lacks a suboption" do
    result = PluginSpecHelper.run("iptables", {
      "chain" => "INPUT", "state" => "absent",
      "tcp_flags" => %({"flags": ["SYN"]}),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: can only join an iterable")
  end

  it "fails with real's NoneType join error when match_set has no match_set_flags" do
    result = PluginSpecHelper.run("iptables", {
      "chain" => "INPUT", "state" => "absent",
      "match_set" => "admin_hosts",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: sequence item 4: expected str instance, NoneType found")
  end

  # real main() builds the rule BEFORE its log-jump enforcement, so the
  # construct_rule crash wins over the log-jump failure. krikri used to
  # check log-jump first and reported the wrong message.
  it "reports the construct_rule crash ahead of the log-jump failure" do
    result = PluginSpecHelper.run("iptables", {
      "chain" => "INPUT", "state" => "absent",
      "tcp_flags" => "{}", "log_level" => "debug", "jump" => "DROP",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: can only join an iterable")
  end

  # The log-jump failure itself, when the rule itself is well-formed.
  it "still reports real's log-jump failure for a well-formed rule" do
    result = PluginSpecHelper.run("iptables", {
      "chain" => "INPUT", "state" => "absent",
      "log_level" => "debug", "jump" => "DROP",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Logging options can only be used with the LOG jump target.")
  end
end
