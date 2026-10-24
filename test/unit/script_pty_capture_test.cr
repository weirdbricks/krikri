require "../minitest_helper"
require "../../src/krikri/plugin_helpers/script_pty_capture"

# Pure shaping for the remote script run's simulated ssh -tt pty session
# (issue #298): real hands the script's remote shell ONE pty, so its two
# streams merge onto the module stdout in execution order with every \n
# turned \r\n by the tty's ONLCR, while the ssh client itself leaves
# exactly one close notice on stderr.
describe "ScriptPtyCapture.pty_stdout" do
  it "renders captured \n output as \r\n (the pty's ONLCR)" do
    Krikri::PluginHelpers::ScriptPtyCapture.pty_stdout("a\nb\nc\n").must_equal("a\r\nb\r\nc\r\n")
  end

  it "keeps the trailing \r\n (real ansible strips nothing here)" do
    Krikri::PluginHelpers::ScriptPtyCapture.pty_stdout("last\n").must_equal("last\r\n")
  end

  it "passes an embedded \r through untouched, like the pty driver does" do
    Krikri::PluginHelpers::ScriptPtyCapture.pty_stdout("a\r\nb\n").must_equal("a\r\r\nb\r\n")
  end

  it "keeps an un-terminated final line un-terminated" do
    Krikri::PluginHelpers::ScriptPtyCapture.pty_stdout("a\nb").must_equal("a\r\nb")
  end

  it "leaves empty capture empty" do
    Krikri::PluginHelpers::ScriptPtyCapture.pty_stdout("").must_equal("")
  end
end

describe "ScriptPtyCapture.connection_closed_stderr" do
  it "builds openssh's mux-client close notice line" do
    Krikri::PluginHelpers::ScriptPtyCapture.connection_closed_stderr("203.0.113.9").must_equal("Shared connection to 203.0.113.9 closed.\r\n")
  end
end
