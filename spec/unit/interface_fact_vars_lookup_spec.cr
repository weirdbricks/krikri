require "../spec_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"
require "../../src/krikri/variable_substitutor/expression_evaluator"
# Pull in the real Ansible-specific Crinja filter registrations, as
# expression_evaluator_spec.cr does - without this the ExpressionEvaluator's
# Crinja env has none of them.
require "../../src/krikri/jinja_filters"

# Round 214 - ricsanfre.dnsmasq on a real Ubuntu 24.04 Kata host failed its
# first real task with "object of type 'dict' has no attribute 'ansible_eth0'"
# evaluating `vars['ansible_' + dnsmasq_interface].ipv4.address` (the role's
# own way of picking the listen address off the default route's interface).
#
# The `vars` magic dict itself was fine - it is a self-view over the same
# flat fact keys that `ansible_eth0` resolves through - the per-interface
# `ansible_<iface>` facts were never GATHERED: FactsGatherer produced
# ansible_interfaces (the name list) but no ansible_eth0 dict at all. Real
# Ansible's LinuxNetwork collector reports every interface as both, and
# inject_facts_as_vars flattens the dict form into the variable namespace,
# which is exactly what the `vars[...]` lookup reads.
describe Krikri::FactsGatherer do
  it "gathers an ansible_<iface> fact dict for every interface in ansible_interfaces" do
    facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h

    interfaces = facts["ansible_interfaces"]?.try(&.as_a?.try(&.map(&.as_s)))
    interfaces.should_not be_nil
    if interfaces
      interfaces.each do |iface|
        iface_fact = facts["ansible_#{iface}"]?.try(&.as_h?)
        iface_fact.should_not be_nil
        next unless iface_fact
        iface_fact["device"].as_s.should eq(iface)
        iface_fact["type"].as_s.should eq(iface == "lo" ? "loopback" : "ether")
      end
    end
  end

  it "carries the default route's address on that interface's ipv4 dict, gateway included" do
    facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h

    default_ipv4 = facts["ansible_default_ipv4"]?.try(&.as_h?)
    default_iface = default_ipv4.try(&.[]?("interface").try(&.as_s?))
    pending "no default route on this host" unless default_ipv4 && default_iface

    iface_fact = facts["ansible_#{default_iface}"]?.try(&.as_h?)
    default_ipv4_h = default_ipv4
    iface_fact.should_not be_nil
    default_ipv4_h.should_not be_nil
    if iface_fact && default_ipv4_h
      ipv4 = iface_fact["ipv4"].as_h
      ipv4["address"].as_s.should eq(default_ipv4_h["address"].as_s)
      ipv4["netmask"].as_s.split(".").size.should eq(4)
      ipv4["network"].as_s.should_not be_empty
      ipv4["gateway"]?.try(&.as_s).should eq(default_ipv4_h["gateway"]?.try(&.as_s))
    end
  end

  it "resolves the role's task-level expression vars['ansible_' + iface].ipv4.address" do
    # The end-to-end contract: whatever gather_facts returns must be
    # resolvable through the same vars-context shape build_vars_context
    # assembles (flat fact keys, plus the `vars` self-view dict built
    # over them) - the exact expression from ricsanfre.dnsmasq's
    # "Set the dnsmasq listen address variable" task, which failed with
    # "object of type 'dict' has no attribute 'ansible_eth0'" before the
    # per-interface facts existed.
    facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h

    vars_context = Hash(String, JSON::Any).new
    facts.each { |key, value| vars_context[key] = value }
    self_view = Hash(String, JSON::Any).new(initial_capacity: vars_context.size)
    vars_context.each { |key, value| self_view[key] = value }
    vars_context["vars"] = JSON::Any.new(self_view)

    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars_context)

    # Dynamic-name lookups against every gathered interface fact must
    # resolve to the same dict the flat form would - never raise "no
    # attribute".
    interfaces = facts["ansible_interfaces"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
    interfaces.each do |iface|
      expected = facts["ansible_#{iface}"].as_h["ipv4"]?.try(&.as_h?.try(&.[]?("address").try(&.as_s?)))
      evaluator.evaluate("vars['ansible_' + '#{iface}'].ipv4.address").should eq(expected || "")
    end
  end

  it "resolves the dnsmasq-shaped expression against a canned eth0 fact, exact-match" do
    # Pinned shape, independent of the spec host's own interfaces: the
    # field names and the dotted/.ipv4/ access path the role uses.
    iface_fact = JSON.parse(%({"device": "eth0", "type": "ether", "mtu": 1500,
      "macaddress": "52:54:00:aa:bb:cc",
      "ipv4": {"address": "192.168.1.50", "netmask": "255.255.255.0",
               "network": "192.168.1.0", "broadcast": "192.168.1.255",
               "gateway": "192.168.1.1"},
      "ipv6": [{"address": "fe80::5054:ff:feaa:bbcc", "prefix": "64", "scope": "link"}]}))

    vars_context = Hash(String, JSON::Any).new
    vars_context["dnsmasq_interface"] = JSON::Any.new("eth0")
    vars_context["ansible_eth0"] = iface_fact
    # build_vars_context also exposes the same facts as the ansible_facts
    # dict (real Ansible's own collected-facts shape, keyed ansible_eth0).
    vars_context["ansible_facts"] = JSON::Any.new({"ansible_eth0" => iface_fact} of String => JSON::Any)
    self_view = Hash(String, JSON::Any).new
    vars_context.each { |key, value| self_view[key] = value }
    vars_context["vars"] = JSON::Any.new(self_view)

    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(vars_context)
    evaluator.evaluate("vars['ansible_' + dnsmasq_interface].ipv4.address").should eq("192.168.1.50")
    evaluator.evaluate("vars['ansible_' + 'eth0'].ipv4.address").should eq("192.168.1.50")
    evaluator.evaluate("vars.ansible_eth0.ipv4.address").should eq("192.168.1.50")
    evaluator.evaluate("ansible_eth0.ipv4.address").should eq("192.168.1.50")
    evaluator.evaluate("ansible_facts.ansible_eth0.ipv4.address").should eq("192.168.1.50")
  end
end
