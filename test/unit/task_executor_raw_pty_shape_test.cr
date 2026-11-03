require "../minitest_helper"
require "../../src/krikri/task_executor/executor_run_loop"
require "../../src/krikri/plugin_helpers/script_pty_capture"
require "../../src/krikri/plugin_helpers/pty_command_runner"

# Issue #490 (eendroroy.pyenv): real ansible runs a remote `raw:` through
# `ssh -tt` (raw sends no stdin), so the target's stdout and stderr arrive
# on the SAME pty (merged in execution order, ONLCR \r\n) and the ssh
# client's own stderr is just its close notice. The stream merge happens
# at the source (ScriptPtyCapture.pty_merged_command wraps the shell
# plugin's invocation in `{ ...; } 2>&1`, so its stderr is empty); the
# decision/shape lives in TaskExecutor.raw_remote_pty_shape (pure,
# testable).
describe Krikri::TaskExecutor do
  describe ".raw_remote_pty_shape" do
    # What a remote raw result looks like BEFORE this shaping now: the
    # shell plugin captured one merged stream (both streams, execution
    # order, still plain \n) and its own stderr is empty.
    def merged_raw_hash
      JSON.parse({
        "rc"           => 1,
        "stdout"       => "out1\nout2\nperl: warning: Setting locale failed.\n",
        "stdout_lines" => ["out1", "out2", "perl: warning: Setting locale failed."],
        "stderr"       => "",
        "stderr_lines" => [] of String,
        "changed"      => true,
        "failed"       => true,
        "msg"          => "non-zero return code",
      }.to_json).as_h
    end

    def raw_hash
      JSON.parse({
        "rc"           => 1,
        "stdout"       => "out1\nout2\n",
        "stdout_lines" => ["out1", "out2"],
        "stderr"       => "perl: warning: Setting locale failed.\n",
        "stderr_lines" => ["perl: warning: Setting locale failed."],
        "changed"      => true,
        "failed"       => true,
        "msg"          => "non-zero return code",
      }.to_json).as_h
    end

    it "shapes a merged remote raw stream into a CRLF pty stdout with only the close notice on stderr" do
      hash = merged_raw_hash
      Krikri::TaskExecutor.raw_remote_pty_shape(hash, true, "203.0.113.9")
      hash["stdout"].as_s
        .must_equal("out1\r\nout2\r\nperl: warning: Setting locale failed.\r\n")
      hash["stdout_lines"].as_a.map(&.as_s)
        .must_equal(["out1", "out2", "perl: warning: Setting locale failed."])
      hash["stderr"].as_s
        .must_equal("Shared connection to 203.0.113.9 closed.\r\n")
      hash["stderr_lines"].as_a.map(&.as_s)
        .must_equal(["Shared connection to 203.0.113.9 closed."])
      hash["rc"].as_i.must_equal(1)
    end

    it "appends an unmerged plugin stderr last when a result reaches it without the merge marker" do
      hash = raw_hash
      Krikri::TaskExecutor.raw_remote_pty_shape(hash, true, "203.0.113.9")
      hash["stdout"].as_s
        .must_equal("out1\r\nout2\r\nperl: warning: Setting locale failed.\r\n")
    end

    it "rewrites a remote raw result's values in place keeping the shaped key order" do
      hash = merged_raw_hash
      original_keys = hash.keys.dup
      Krikri::TaskExecutor.raw_remote_pty_shape(hash, true, "203.0.113.9")
      hash.keys.must_equal(original_keys)
    end

    it "leaves a local raw result's streams untouched" do
      hash = merged_raw_hash
      before = JSON.parse(hash.to_json).as_h
      Krikri::TaskExecutor.raw_remote_pty_shape(hash, false, "203.0.113.9")
      hash.must_equal(before)
    end

    it "shapes a merged empty-stderr capture ending in one newline to stdout out1 CRLF out2 CRLF" do
      hash = JSON.parse({
        "rc"           => 0,
        "stdout"       => "out1\nout2\n",
        "stdout_lines" => ["out1", "out2"],
        "stderr"       => "",
        "stderr_lines" => [] of String,
        "changed"      => true,
        "failed"       => false,
      }.to_json).as_h
      Krikri::TaskExecutor.raw_remote_pty_shape(hash, true, "203.0.113.9")
      hash["stdout"].as_s.must_equal("out1\r\nout2\r\n")
      hash["stdout_lines"].as_a.map(&.as_s).must_equal(["out1", "out2"])
    end

    # Issue #775: when the shell plugin captured the command on a REAL
    # target-side pty, its stdout already IS the sshd-shaped pty stream -
    # re-applying the pipe emulation's ONLCR pass would double every \r.
    it "keeps a real-pty-marked stdout verbatim, swaps stderr for the close notice and strips the marker" do
      hash = JSON.parse({
        "rc"               => 1,
        "stdout"           => "out1\r\nerr1\r\n",
        "stdout_lines"     => ["out1", "err1"],
        "stderr"           => "",
        "stderr_lines"     => [] of String,
        "changed"          => true,
        "failed"           => true,
        "msg"              => "non-zero return code",
        "_krikri_real_pty" => true,
      }.to_json).as_h
      Krikri::TaskExecutor.raw_remote_pty_shape(hash, true, "203.0.113.9")
      hash["stdout"].as_s.must_equal("out1\r\nerr1\r\n")
      hash["stdout_lines"].as_a.map(&.as_s).must_equal(["out1", "err1"])
      hash["stderr"].as_s
        .must_equal("Shared connection to 203.0.113.9 closed.\r\n")
      hash["stderr_lines"].as_a.map(&.as_s)
        .must_equal(["Shared connection to 203.0.113.9 closed."])
      hash.has_key?("_krikri_real_pty").must_equal(false)
    end

    # The emulation path must keep working for a result whose plugin could
    # not allocate a pty - a marker absent from the wire keeps the old
    # merge-and-translate behavior byte for byte.
    it "still applies the pipe-emulation shaping when no real-pty marker rode the result" do
      hash = merged_raw_hash
      Krikri::TaskExecutor.raw_remote_pty_shape(hash, true, "203.0.113.9")
      hash["stdout"].as_s
        .must_equal("out1\r\nout2\r\nperl: warning: Setting locale failed.\r\n")
    end
  end

  describe ".exec via PluginHelpers::PtyCommandRunner" do
    # nil here means "no pty could be allocated" - a capability every
    # Linux test host has, so treat its absence as the spec's own failure.
    def pty_exec(command : String)
      PluginHelpers::PtyCommandRunner.exec(command) || raise "pty allocation failed"
    end

    it "gives the command a real tty on stdout, like real's ssh -tt session" do
      pty_exec("if [ -t 1 ]; then echo tty; else echo pipe; fi")[:stdout].must_equal("tty\r\n")
    end

    it "captures stdout and stderr merged in execution order with ONLCR newlines and empty stderr" do
      result = pty_exec("echo out1; echo err1 >&2; echo out2")
      result[:stdout].must_equal("out1\r\nerr1\r\nout2\r\n")
      result[:stderr].must_equal("")
    end

    it "propagates the command's own exit code through the pty session" do
      pty_exec("echo boom >&2; exit 3")[:exit_code].must_equal(3)
    end

    it "round-trips a literal CRLF through the pty's ONLCR without doubling the CR" do
      # A command that writes "\r\n" itself must come back "\r\r\n" off a
      # real pty (kernel ONLCR), not "\r\n" - the exact bytes real's
      # capture carries.
      pty_exec("printf 'a\\r\\nb\\n'")[:stdout].must_equal("a\r\r\nb\r\n")
    end
  end

  describe "shell plugin __raw_pty_merge capture" do
    it "captures a merge-marked command on a real pty, with CRLF stdout, empty stderr and the real-pty marker" do
      result = PluginSpecHelper.run("shell", {
        "cmd"             => "echo out1; echo err1 >&2",
        "__raw_pty_merge" => "1",
      })
      result["stdout"].as_s.must_equal("out1\r\nerr1\r\n")
      result["stderr"].as_s.must_equal("")
      result["_krikri_real_pty"].as_bool?.must_equal(true)
      result["rc"].as_i.must_equal(0)
    end

    it "keeps the plain two-stream capture for a shell run without the merge marker" do
      result = PluginSpecHelper.run("shell", {"cmd" => "echo out1; echo err1 >&2"})
      result["stdout"].as_s.must_equal("out1")
      result["stderr"].as_s.must_equal("err1")
      result["_krikri_real_pty"]?.must_be_nil
    end
  end

  describe ".strip_trailing_newlines? via ScriptPtyCapture" do
    # Real's raw action returns the pty capture untouched (no command
    # module's strip_empty_ends applies to it), so the merged stream's
    # trailing newline must survive to stdout for the pty shape.
    it "never strips a pty-merged capture regardless of the requested strip_empty_ends" do
      PluginHelpers::ScriptPtyCapture.strip_trailing_newlines?(true, true).must_equal(false)
      PluginHelpers::ScriptPtyCapture.strip_trailing_newlines?(false, true).must_equal(false)
    end

    it "follows the requested strip_empty_ends for plain-pipe captures" do
      PluginHelpers::ScriptPtyCapture.strip_trailing_newlines?(true, false).must_equal(true)
      PluginHelpers::ScriptPtyCapture.strip_trailing_newlines?(false, false).must_equal(false)
    end
  end

  describe ".pty_merged_command via ScriptPtyCapture" do
    it "wraps a merge-marked command in the 2>&1 group so one pipe carries both streams in order" do
      # The group is what guarantees the ORDER real's pty shows (a warn
      # on stderr printed before an out1 on stdout reaches the capture
      # as "warn\nout1\n"): both streams ride one pipe, so the shaping
      # below never has to guess an interleaving.
      PluginHelpers::ScriptPtyCapture.pty_merged_command(
        "/bin/sh -c 'echo warn >&2; echo out1'", true
      ).must_equal("{ /bin/sh -c 'echo warn >&2; echo out1'; } 2>&1")
    end

    it "passes an unmarked command through unwrapped so local raw keeps two captured streams" do
      PluginHelpers::ScriptPtyCapture.pty_merged_command("echo hi", false).must_equal("echo hi")
    end

    it "renders a merged warn-then-out1 capture as warn first in the CRLF pty stdout" do
      PluginHelpers::ScriptPtyCapture.pty_stdout("warn\nout1\n").must_equal("warn\r\nout1\r\n")
    end
  end
end
