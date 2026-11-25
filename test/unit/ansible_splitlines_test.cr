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

  it "splits apt's uncoloured CRLF repaint meter into the line list real ansible printed (issue #1789)" do
    # Verbatim head and tail of crivetimihai.bootstrap's `raw: apt-get
    # update && apt-get install -y python ...` stdout as real ansible
    # captured it (round 1795578916's cold run): apt repaints one line
    # per tick, so stdout_lines must carry each repaint as its own empty
    # or partial entry rather than one merged line, and an empty entry
    # opens the stream because it begins with the \r that starts a repaint.
    stdout = "\r0% [Working]\r            \r" \
             "Hit:1 http://security.ubuntu.com/ubuntu noble-security InRelease\r\n" \
             "\r0% [Waiting for headers]\r0% [Waiting for headers]\r                        \r" \
             "Hit:2 http://archive.ubuntu.com/ubuntu noble InRelease\r\n" \
             "Package python is not available, but is referred to by another package.\r\n" \
             "This may mean that the package is missing, has been obsoleted, or\r\n" \
             "is only available from another source\r\n" \
             "However the following packages replace it:\r\n" \
             "  2to3 python-is-python3\r\n" \
             "\r\n" \
             "E: Package 'python' has no installation candidate\r\n"

    Krikri::PluginHelpers::AnsibleSplitlines.split(stdout).must_equal([
      "",
      "0% [Working]",
      "            ",
      "Hit:1 http://security.ubuntu.com/ubuntu noble-security InRelease",
      "",
      "0% [Waiting for headers]",
      "0% [Waiting for headers]",
      "                        ",
      "Hit:2 http://archive.ubuntu.com/ubuntu noble InRelease",
      "Package python is not available, but is referred to by another package.",
      "This may mean that the package is missing, has been obsoleted, or",
      "is only available from another source",
      "However the following packages replace it:",
      "  2to3 python-is-python3",
      "",
      "E: Package 'python' has no installation candidate",
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

  # Issue #1811: a script's stderr carried a raw 0xFF byte; real ansible's
  # stderr_lines kept the surrogateescape character for it (displayed as
  # "?") while krikri's each_char decode turned it into U+FFFD and showed
  # that. The engine's own representation of the byte is the private-use
  # twin, one character for one byte.
  it "keeps a non-UTF-8 byte as one undecodable character, not U+FFFD" do
    stderr = String.new(Bytes[0x01, 0x6b, 0x70, 0x67, 0xff, 0x3a, 0x20, 0x78, 0x0a])
    Krikri::PluginHelpers::AnsibleSplitlines.split(stderr).must_equal(["\u0001kpg\u{F7FF}: x"])
  end
end
