require "../minitest_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Ansible's interpreter discovery (interpreter_discovery.py) is a
# `command -v` probe over the INTERPRETER_PYTHON_FALLBACK list through
# the connection's shell, first absolute path wins, /usr/bin/python3
# when nothing does - so a Ubuntu 22.04 target discovers the VERSIONED
# /usr/bin/python3.10, which real then executes even for tasks that run
# on the controller under `connection: local` (issue #374). The parser
# half is pinned here; the executor's missing-interpreter failure for
# the local dispatch is covered by
# test/integration/local_connection_missing_interpreter_test.cr.
describe "Krikri::FactsGatherer interpreter discovery (facts_interpreter_discovery_test.cr)" do
  describe ".parse_discovery_output" do
    it "takes the first absolute path the bootstrap printed" do
      raw = "FOUND\n/usr/bin/python3.13\n/usr/bin/python3\nENDFOUND"
      Krikri::FactsGatherer.parse_discovery_output(raw).must_equal({"/usr/bin/python3.13", true})
    end

    it "ignores bare (non-absolute) command -v output like real's startswith('/') filter" do
      raw = "FOUND\npython3.13\npython3\nENDFOUND"
      Krikri::FactsGatherer.parse_discovery_output(raw).must_equal({"/usr/bin/python3", false})
    end

    it "falls back to /usr/bin/python3 with the found flag when nothing matched" do
      raw = "FOUND\n\nENDFOUND"
      Krikri::FactsGatherer.parse_discovery_output(raw).must_equal({"/usr/bin/python3", false})
    end

    it "falls back to /usr/bin/python3 with the found flag on unparseable output (real's caught-ValueError path)" do
      Krikri::FactsGatherer.parse_discovery_output("sh: command: not found\n").must_equal({"/usr/bin/python3", true})
    end
  end

  describe ".discover_python_interpreter" do
    it "resolves an absolute interpreter path through the local /bin/sh" do
      interpreter, found = Krikri::FactsGatherer.discover_python_interpreter
      interpreter.must_match(/\A\//)
      # found is false only when this machine has no python at all in the
      # fallback list's paths - krikri's own filter/lookup runners need a
      # controller python3, so treat that as an environment failure.
      found.must_equal(true)
    end
  end

  describe "discovered_interpreter_python stamp" do
    it "is not stamped when a configured ansible_python_interpreter exists (real never runs discovery then)" do
      config = JSON.parse(%({"host":{"name":"localhost","user":"root","port":22},"params":{"_first_gather":"true","ansible_python_interpreter":"/usr/bin/python3"},"vars":{}}))
      result = JSON.parse(Krikri::FactsGatherer.run(config))
      result["ansible_facts"].as_h.keys.wont_include("discovered_interpreter_python")
    end

    it "is stamped on the first gather when discovery ran (W1 shape kept)" do
      config = JSON.parse(%({"host":{"name":"localhost","user":"root","port":22},"params":{"_first_gather":"true"},"vars":{}}))
      result = JSON.parse(Krikri::FactsGatherer.run(config))
      stamp = result["ansible_facts"]["discovered_interpreter_python"].as_s
      stamp.must_match(/\A\//)
      # The discovery warning rides the controller-side marker, never the
      # facts themselves.
      result["ansible_facts"].as_h.keys.wont_include("_ansible_discovery_warning")
      warnings = result["_ansible_discovery_warning"].as_a
      warnings.size.must_equal(1)
      warnings[0].as_s.must_equal("Host 'localhost' is using the discovered Python interpreter at '#{stamp}', but future installation of another Python interpreter could cause a different interpreter to be discovered. See https://docs.ansible.com/ansible-core/2.19/reference_appendices/interpreter_discovery.html for more information.")
    end

    it "carries no discovery warning on a later gather (discovery is cached in real)" do
      config = JSON.parse(%({"host":{"name":"localhost","user":"root","port":22},"params":{},"vars":{}}))
      result = JSON.parse(Krikri::FactsGatherer.run(config))
      result.as_h.keys.wont_include("_ansible_discovery_warning")
    end
  end
end
