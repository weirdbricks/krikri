require "../minitest_helper"
require "../../src/krikri/plugin_helpers/interpreter_probe"

# The one-shot ssh probe TaskExecutor#remote_interpreter_probe sends to
# decide whether a configured module interpreter exists on the target, and
# the parser for its answer. Real ansible runs every module payload under
# that interpreter, so this verdict decides whether the task runs at all
# (issue #1646: t_woerner.ipareplica's ipaclient_test over ssh).
describe "Krikri::PluginHelpers::InterpreterProbe" do
  describe ".script" do
    it "tests an absolute path for executability" do
      script = Krikri::PluginHelpers::InterpreterProbe.script("/usr/bin/python2")
      script.includes?("if test -x '/usr/bin/python2';").must_equal(true, script)
      script.includes?(Krikri::PluginHelpers::InterpreterProbe::PRESENT).must_equal(true, script)
      script.includes?(Krikri::PluginHelpers::InterpreterProbe::MISSING).must_equal(true, script)
    end

    it "looks a bare name up on PATH, the way real's pin resolves" do
      script = Krikri::PluginHelpers::InterpreterProbe.script("python3")
      script.includes?("if command -v 'python3' >/dev/null 2>&1;").must_equal(true, script)
    end

    it "quotes an interpreter path carrying a single quote" do
      script = Krikri::PluginHelpers::InterpreterProbe.script("/tmp/it's/python3")
      script.includes?("'/tmp/it'\\''s/python3'").must_equal(true, script)
    end
  end

  describe ".parse" do
    it "reports a missing interpreter and a dash /bin/sh" do
      Krikri::PluginHelpers::InterpreterProbe.parse(
        "krikri-interpreter-missing\n/usr/bin/dash\n").must_equal({true, true})
    end

    it "reports a missing interpreter and a non-dash /bin/sh" do
      Krikri::PluginHelpers::InterpreterProbe.parse(
        "krikri-interpreter-missing\n/bin/bash\n").must_equal({true, false})
    end

    it "reports a present interpreter" do
      Krikri::PluginHelpers::InterpreterProbe.parse(
        "krikri-interpreter-present\n").must_equal({false, true})
    end

    # A probe that never answered (an ssh failure, a shell that refused the
    # command) must read as PRESENT: inventing real's interpreter-not-found
    # failure would fail a task real runs fine.
    it "treats an unrecognisable transcript as present" do
      Krikri::PluginHelpers::InterpreterProbe.parse("").must_equal({false, true})
      Krikri::PluginHelpers::InterpreterProbe.parse("Permission denied\n").must_equal({false, true})
    end
  end
end
