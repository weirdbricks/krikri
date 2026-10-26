require "../minitest_helper"
require "../../src/krikri/plugin_daemon"

# The controller's start-up greeting check (PluginDaemon.await_ready). A
# plugin binary without the --daemon entry point reads stdin to EOF and
# never answers, so without this check the first request blocks until the
# full request timeout. Every case here runs against a small local process,
# so the wait is bounded without SSH.
private def silent_process : Process
  Process.new("/bin/sh", ["-c", "sleep 30"],
    input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)
end

private def process_writing(payload : String) : Process
  Process.new("/bin/sh", ["-c", "printf '#{payload}'"],
    input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)
end

describe "PluginDaemon.await_ready" do
  it "accepts the ready greeting frame" do
    # 4-byte big-endian length (18) followed by {"daemon":"ready"}.
    process = process_writing(%(\\000\\000\\000\\022{"daemon":"ready"}))
    begin
      Krikri::PluginDaemon.await_ready(process.output, 5)
    ensure
      process.terminate(graceful: false) unless process.terminated?
    end
  end

  it "rejects a frame that is not the ready greeting" do
    # 4-byte big-endian length (17) followed by {"daemon":"nope"}.
    process = process_writing(%(\\000\\000\\000\\021{"daemon":"nope"}))
    begin
      error = assert_raises(Exception) do
        Krikri::PluginDaemon.await_ready(process.output, 5)
      end
      error.message.to_s.includes?("was not 'ready'").must_equal(true)
    ensure
      process.terminate(graceful: false) unless process.terminated?
    end
  end

  it "fails at once when the process exits without greeting" do
    process = Process.new("/bin/sh", ["-c", "exit 1"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)
    started = Time.instant
    assert_raises(IO::EOFError) do
      Krikri::PluginDaemon.await_ready(process.output, 60)
    end
    ((Time.instant - started).total_seconds < 10.0).must_equal(true)
  end

  it "fails at the handshake timeout when the process stays silent" do
    process = silent_process
    begin
      started = Time.instant
      error = assert_raises(Exception) do
        Krikri::PluginDaemon.await_ready(process.output, 1)
      end
      error.message.to_s.includes?("did not greet within 1s").must_equal(true)
      ((Time.instant - started).total_seconds < 10.0).must_equal(true)
    ensure
      process.terminate(graceful: false) unless process.terminated?
    end
  end

  it "accepts the real --daemon binary's own greeting" do
    binary = File.join(PluginSpecHelper::PLUGINS_DIR, ".fat-plugin")
    skip "fat plugin binary not built (run ./build.sh first)" unless File.exists?(binary)

    process = Process.new(binary, ["--daemon"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)
    begin
      Krikri::PluginDaemon.await_ready(process.output, 30)
    ensure
      process.terminate(graceful: false) unless process.terminated?
    end
  end
end
