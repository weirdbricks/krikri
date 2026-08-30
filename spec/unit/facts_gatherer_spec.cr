require "../spec_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# OPUS_PERFORMANCE_IMPROVEMENTS.md item 2 - `facts` under the daemon.
#
# The item itself is one line (drop "facts" from
# DAEMON_INELIGIBLE_PLUGINS); the actual work, and the actual risk, was
# getting `facts` INTO the fat plugin binary so a daemon request for it
# does not hit the generated dispatcher's "unknown plugin" fallback.
# That meant lifting the whole gathering body out of the top level of
# `plugins/facts.cr` into `Krikri::FactsGatherer`, which is exactly
# the kind of move that quietly changes a payload.
#
# So what is pinned here is the CONTRACT the extraction had to preserve:
# the same three top-level keys, no others (notably no `msg` on the
# success path - the reason this was not reshaped into a BasePlugin
# subclass, whose PluginResult always emits one), and gather_subset
# still honoured. The live daemon round trip is verified separately in
# plugin_daemon_spec.cr.
describe Krikri::FactsGatherer do
  it "returns the same three top-level keys the standalone driver always emitted" do
    result = JSON.parse(Krikri::FactsGatherer.run(nil))

    result.as_h.keys.sort!.should eq(["ansible_facts", "changed", "failed"])
    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
    # An always-empty "msg" would be the tell-tale of a BasePlugin
    # reshape; there has never been one on the success payload.
    result["msg"]?.should be_nil
  end

  it "gathers a full fact set with no config at all" do
    facts = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h

    # Spot-check the families every real role reads first.
    facts["ansible_system"]?.should_not be_nil
    facts["ansible_os_family"]?.should_not be_nil
    facts["ansible_distribution"]?.should_not be_nil
    facts["ansible_hostname"]?.should_not be_nil
  end

  it "honours gather_subset from the config it is handed" do
    # The daemon hands over an already-parsed JSON::Any rather than a
    # STDIN string, so this is the shape that matters now.
    config = JSON.parse(%({"host":{"name":"localhost","user":"root","port":22},"params":{"gather_subset":"min"},"vars":{}}))

    full = JSON.parse(Krikri::FactsGatherer.run(nil))["ansible_facts"].as_h
    minimal = JSON.parse(Krikri::FactsGatherer.run(config))["ansible_facts"].as_h

    minimal.size.should be < full.size
    # min still carries the identity facts - it drops families, not
    # the basics every play needs.
    minimal["ansible_system"]?.should_not be_nil
    minimal["ansible_distribution"]?.should_not be_nil
  end

  it "tolerates a config carrying no params at all" do
    config = JSON.parse(%({"host":{"name":"localhost","user":"root","port":22},"vars":{}}))
    result = JSON.parse(Krikri::FactsGatherer.run(config))

    result["failed"].as_bool.should be_false
    result["ansible_facts"].as_h.should_not be_empty
  end
end
