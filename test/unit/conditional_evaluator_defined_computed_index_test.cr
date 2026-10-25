require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"

# guidugli.firewall's "Disable conflicting firewall services when present"
# loop (issue #352): each loop item gates its task on
# `ansible_facts.services[item ~ '.service'] is defined and ... .status !=
# 'not-found'`. Real ansible evaluates the computed subscript against the
# gathered service_facts and RUNS the nftables item; krikri's
# `is defined` branch handed the operand text (index expression included)
# to VariableLookup, whose index-key resolution had no notion of a computed
# key and used the whole unevaluated text `item ~ '.service'` as the dict
# key - always missing, so the task skipped while ansible ran it.
describe "Krikri::ConditionalEvaluator (conditional_evaluator_defined_computed_index_test.cr)" do
  describe "is defined with a computed bracket index (issue #352)" do
    def service_facts_vars(item : String, service_mgr : String = "systemd")
      services = {
        "nftables.service" => JSON::Any.new({"status" => JSON::Any.new("enabled"), "state" => JSON::Any.new("stopped"), "name" => JSON::Any.new("nftables"), "source" => JSON::Any.new("systemd")}),
        "sshd.service"     => JSON::Any.new({"status" => JSON::Any.new("enabled"), "state" => JSON::Any.new("running"), "name" => JSON::Any.new("sshd"), "source" => JSON::Any.new("systemd")}),
      } of String => JSON::Any
      {
        "ansible_facts" => JSON::Any.new({"services" => JSON::Any.new(services), "service_mgr" => JSON::Any.new(service_mgr)}),
        "item"          => JSON::Any.new(item),
      } of String => JSON::Any
    end

    it "is defined: true when the tilde-computed index hits an existing service" do
      vars = service_facts_vars("nftables")
      Krikri::ConditionalEvaluator.evaluate("ansible_facts.services[item ~ '.service'] is defined", vars).must_equal(true)
    end

    it "is defined: false when the tilde-computed index misses (service absent)" do
      # Same services dict, but the loop item names a service that
      # service_facts never gathered - exactly the case ansible's own
      # `is defined` test uses to skip a conflicting-firewall item.
      vars = service_facts_vars("iptables")
      Krikri::ConditionalEvaluator.evaluate("ansible_facts.services[item ~ '.service'] is defined", vars).must_equal(false)
    end

    it "is not defined: true for the absent service, false for the present one" do
      present = service_facts_vars("nftables")
      absent = service_facts_vars("iptables")
      Krikri::ConditionalEvaluator.evaluate("ansible_facts.services[item ~ '.service'] is not defined", present).must_equal(false)
      Krikri::ConditionalEvaluator.evaluate("ansible_facts.services[item ~ '.service'] is not defined", absent).must_equal(true)
    end

    it "plus-computed and quoted-left-tilde-computed index spellings hit the same key" do
      # Both alternates real playbooks use for the same lookup: `'name' +
      # '.service'` (string concatenation) and a quoted literal as the
      # left `~` operand (`'nftables' ~ '.service'`). The quoted-left
      # spelling additionally pins the quoted-index-literal fix: its text
      # starts AND ends with `'`, which the old first/last-char literal
      # check misread as one literal spanning the whole index.
      vars = service_facts_vars("nftables")
      Krikri::ConditionalEvaluator.evaluate("ansible_facts.services[item + '.service'] is defined", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("ansible_facts.services['nftables' ~ '.service'] is defined", vars).must_equal(true)
    end

    it "still recognizes a fully-quoted literal index after the stricter literal check" do
      # `'nftables.service'` is ONE literal spanning the whole index -
      # the strict quoted-literal check must keep answering it directly,
      # not route it into the computed-expression path.
      vars = service_facts_vars("nftables")
      Krikri::ConditionalEvaluator.evaluate("ansible_facts.services['nftables.service'] is defined", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("ansible_facts.services['iptables.service'] is defined", vars).must_equal(false)
    end

    it "parenthesized and/or compound shape with the .status comparison runs the nftables item" do
      # guidugli.firewall's real `when:` shape (parenthesised and-clause
      # on the left, its or-alternative on the right): every operand must
      # reach the same computed-index-aware definedness answer, and the
      # non-defined status comparison must agree with the test above it.
      vars = service_facts_vars("nftables")
      condition = "(ansible_facts['service_mgr'] | default('') == 'systemd' and " \
                  "ansible_facts.services[item ~ '.service'] is defined and " \
                  "ansible_facts.services[item ~ '.service'].status != 'not-found')"
      Krikri::ConditionalEvaluator.evaluate(condition, vars).must_equal(true)
    end

    it "parenthesized and/or compound shape skips an absent service" do
      # The same compound, with the loop item's service genuinely absent:
      # ansible skips the task, so the whole and-chain must come out
      # False.
      vars = service_facts_vars("iptables")
      condition = "(ansible_facts['service_mgr'] | default('') == 'systemd' and " \
                  "ansible_facts.services[item ~ '.service'] is defined and " \
                  "ansible_facts.services[item ~ '.service'].status != 'not-found')"
      Krikri::ConditionalEvaluator.evaluate(condition, vars).must_equal(false)
    end
  end
end
