require "../minitest_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Ansible prints a full failed-setup block (cause chain, sub-event box,
# fatal line with the failed_modules payload) when the implicit setup
# module dies with rc 127 on a missing interpreter - and the shell error
# text inside that payload differs by transport (remote SSH vs local).
describe "Krikri::FactsGatherer.interpreter_missing_report (facts_interpreter_report_test.cr)" do
  # Trailing spaces on the "|" lines are part of ansible's observed
  # output; the escaped \n inside the JSON string is how ansible shows
  # the controller's shell error inside the failed_modules payload.
  it "prints the exact local-form block for a missing interpreter" do
    # Array of lines joined with "\n" instead of a heredoc so the "| "
    # lines can carry their trailing space (ansible's observed output)
    # without putting trailing whitespace in the source.
    expected = [
      "[ERROR]: Task failed: Action failed: The following modules failed to execute: ansible.legacy.setup.",
      "",
      "Task failed: Action failed.",
      "",
      "<<< caused by >>>",
      "",
      "The following modules failed to execute: ansible.legacy.setup.",
      "",
      "+--[ Sub-Event 1 of 1 ]---",
      "| ",
      "| The module interpreter '/home/core/bin/python' was not found. Consider overriding the configured interpreter path for this host. See stdout/stderr for the returned output.",
      "| ",
      "+--[ End Sub-Event ]---",
      "",
      "fatal: [testhost]: FAILED! => {\"ansible_facts\": {}, \"changed\": false, \"failed_modules\": {\"ansible.legacy.setup\": {\"exception\": \"(traceback unavailable)\", \"failed\": true, \"module_stderr\": \"/bin/sh: 1: /home/core/bin/python: not found\\n\", \"module_stdout\": \"\", \"msg\": \"The module interpreter '/home/core/bin/python' was not found.\", \"rc\": 127}}, \"msg\": \"The following modules failed to execute: ansible.legacy.setup.\"}",
    ].join("\n")
    Krikri::FactsGatherer.interpreter_missing_report("testhost", "/home/core/bin/python", "testhost", false).must_equal(expected.chomp)
  end

  it "uses the remote shell error and connection-closed stderr for an SSH gather" do
    report = Krikri::FactsGatherer.interpreter_missing_report("web1", "/usr/bin/python3", "10.0.0.5", true)
    report.must_include("module_stderr\": \"Shared connection to 10.0.0.5 closed.\\r\\n\"")
    report.must_include("module_stdout\": \"/bin/sh: line 1: /usr/bin/python3: No such file or directory\\r\\n\"")
  end

  it "uses dash's remote shell error when the target's /bin/sh is dash" do
    report = Krikri::FactsGatherer.interpreter_missing_report("web1", "/usr/bin/env python3", "10.0.0.5", true, true)
    report.must_include("module_stderr\": \"Shared connection to 10.0.0.5 closed.\\r\\n\"")
    report.must_include("module_stdout\": \"/bin/sh: 1: /usr/bin/env python3: not found\\r\\n\"")
    report.wont_include("line 1:")
  end
end
