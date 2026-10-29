require "../minitest_helper"
require "../../src/krikri/plugin_helpers/ansible_splitlines"

# Parity with Python's str.splitlines() as Ansible uses it to derive
# stdout_lines/stderr_lines (ansible/plugins/action/__init__.py's
# txt.splitlines()), verified live against python3 and against real
# ansible-playbook - not Crystal's String#split("\n").
describe "AnsibleSplitlines" do
  it "splits curl's \r progress-meter stderr like Python's splitlines (issue #614)" do
    Krikri::PluginHelpers::AnsibleSplitlines
      .split("  % Total\n                 Dload\n\r  0     0\r100  4619\nPython version 2.7")
      .must_equal([
        "  % Total",
        "                 Dload",
        "",
        "  0     0",
        "100  4619",
        "Python version 2.7",
      ])
  end

  it "counts \r\n as a single break, not two" do
    Krikri::PluginHelpers::AnsibleSplitlines.split("a\r\nb\r\nc").must_equal(["a", "b", "c"])
    Krikri::PluginHelpers::AnsibleSplitlines.split("a\r\r\nb").must_equal(["a", "", "b"])
  end

  it "splits on each of the extended Python boundary characters" do
    {
      '\v'     => ["a", "b"],
      '\f'     => ["a", "b"],
      '\u001c' => ["a", "b"],
      '\u001d' => ["a", "b"],
      '\u001e' => ["a", "b"],
      '\u0085' => ["a", "b"],
      '\u2028' => ["a", "b"],
      '\u2029' => ["a", "b"],
      '\r'     => ["a", "b"],
      '\n'     => ["a", "b"],
    }.each do |boundary, expected|
      Krikri::PluginHelpers::AnsibleSplitlines.split("a#{boundary}b").must_equal(expected)
    end
  end

  it "does not add a trailing empty element for a trailing boundary" do
    splitter = Krikri::PluginHelpers::AnsibleSplitlines
    splitter.split("a\n").must_equal(["a"])
    splitter.split("\n").must_equal([""])
    splitter.split("a\n\r").must_equal(["a", ""])
    splitter.split("\n\n").must_equal(["", ""])
    splitter.split("a\r\n").must_equal(["a"])
  end

  it "returns [] for empty input, not [\"\"]" do
    Krikri::PluginHelpers::AnsibleSplitlines.split("").must_equal([] of String)
  end
end
