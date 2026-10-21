require "../minitest_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Ansible's setup module runs under the host's configured
# ansible_python_interpreter and fails Gathering Facts with rc 127
# when that interpreter is missing on the target; the facts gatherer
# reproduces that failure only when it can tell the configured path is
# not executable on this machine - which is what interpreter_missing?
# decides.
describe "Krikri::FactsGatherer.interpreter_missing? (facts_interpreter_missing_test.cr)" do
  it "reports an existing executable absolute path as present" do
    Krikri::FactsGatherer.interpreter_missing?("/bin/sh").must_equal(false)
  end

  it "reports a nonexistent absolute path as missing" do
    Krikri::FactsGatherer.interpreter_missing?("/nonexistent/krikri-test/interpreter").must_equal(true)
  end

  it "reports a bare name that exists on PATH as present" do
    Krikri::FactsGatherer.interpreter_missing?("sh").must_equal(false)
  end

  it "reports a bare name that does not exist on PATH as missing" do
    Krikri::FactsGatherer.interpreter_missing?("krikri-no-such-interpreter").must_equal(true)
  end

  it "never reports an auto discovery request as missing" do
    Krikri::FactsGatherer.interpreter_missing?("auto").must_equal(false)
    Krikri::FactsGatherer.interpreter_missing?("auto_silent").must_equal(false)
  end
end
