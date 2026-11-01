require "../minitest_helper"
require "file_utils"
require "../../src/krikri/python_filter_runner"
require "../../src/krikri/python_test_runner"
require "../../src/krikri/python_lookup_runner"
require "../../src/krikri/python_action_runner"

# Issue #705: only a failure BEFORE the wrapper process exists is a
# spawn failure (LocalExecutor's #704 rule). A wrapper that RAN and
# exited without answering keeps the pre-#705 verdicts: the call paths
# say "produced no result (is python3 available?)", and the
# introspection path neither retries nor emits a spawn warning.
#
# The deterministic stand-in for "python3 spawned, then died before
# reading its stdin" is a fake python3 first on PATH that appends to a
# counter file and exits 3 immediately; the runners write a payload
# larger than the pipe buffer (256KB), so the old whole-Process.run
# classification surfaced its EPIPE as a spawn failure.
describe "Python wrapper spawn classification (#705 post-spawn)" do
  exclusive! # ENV["PATH"] is process-wide

  BIG       = "x" * (256 * 1024)
  NO_ARGS   = [] of JSON::Any
  NO_KWARGS = {} of String => JSON::Any

  private def with_fake_python3(counter : String, &) : Nil
    bin = File.join(Dir.tempdir, "krikri-fakepy-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(bin)
    fake = File.join(bin, "python3")
    File.write(fake, "#!/bin/sh\nprintf x >> '#{counter}'\nexit 3\n")
    File.chmod(fake, 0o755)
    previous = ENV["PATH"]
    ENV["PATH"] = "#{bin}:#{previous}"
    begin
      yield
    ensure
      ENV["PATH"] = previous
      FileUtils.rm_r(bin)
    end
  end

  it "reports a filter wrapper that ran and died as produced-no-result, not a spawn failure" do
    root = File.join(Dir.tempdir, "krikri-spawncls-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(root)
    plugin = File.join(root, "myfilter.py")
    File.write(plugin, "# test plugin")
    counter = File.join(root, "spawn-counter")
    File.write(counter, "")

    with_fake_python3(counter) do
      ex = assert_raises(Krikri::PythonFilterRunner::FilterError) do
        Krikri::PythonFilterRunner.call_filter("myfilter", [plugin],
          JSON::Any.new(BIG), NO_ARGS, NO_KWARGS)
      end
      ex.message.to_s.must_match(/produced no result/)
      ex.message.to_s.wont_match(/failed to spawn/)
    end
  ensure
    FileUtils.rm_r(root) if root
  end

  it "does not retry or warn on introspection when the wrapper ran and died" do
    root = File.join(Dir.tempdir, "krikri-spawncls-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(root)
    plugin = File.join(root, "myfilter.py")
    File.write(plugin, "# test plugin")
    counter = File.join(root, "spawn-counter")
    File.write(counter, "")

    captured = IO::Memory.new
    previous = Krikri::PythonFilterRunner.warning_sink
    with_fake_python3(counter) do
      Krikri::PythonFilterRunner.warning_sink = captured
      Krikri::PythonFilterRunner.filter_names([plugin]).must_be_empty
    ensure
      Krikri::PythonFilterRunner.warning_sink = previous
    end

    # exactly one spawn: no transient-class retry happened
    File.read(counter).must_equal("x")
    captured.to_s.wont_match(/introspection failed/)
    captured.to_s.wont_match(/Failed to spawn process/)
  ensure
    FileUtils.rm_r(root) if root
  end

  it "reports a test wrapper that ran and died as produced-no-result, not a spawn failure" do
    root = File.join(Dir.tempdir, "krikri-spawncls-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(root)
    plugin = File.join(root, "mytest.py")
    File.write(plugin, "# test plugin")
    counter = File.join(root, "spawn-counter")
    File.write(counter, "")

    with_fake_python3(counter) do
      ex = assert_raises(Krikri::PythonTestRunner::TestError) do
        Krikri::PythonTestRunner.call_test("mytest", [plugin],
          JSON::Any.new(BIG), NO_ARGS, NO_KWARGS)
      end
      ex.message.to_s.must_match(/produced no result/)
      ex.message.to_s.wont_match(/failed to spawn/)
    end
  ensure
    FileUtils.rm_r(root) if root
  end

  it "reports a lookup wrapper that ran and died as produced-no-result, not a spawn failure" do
    root = File.join(Dir.tempdir, "krikri-spawncls-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(root)
    plugin = File.join(root, "mylookup.py")
    File.write(plugin, "# test plugin")
    counter = File.join(root, "spawn-counter")
    File.write(counter, "")

    with_fake_python3(counter) do
      ex = assert_raises(Krikri::PythonLookupRunner::LookupUnavailableError) do
        Krikri::PythonLookupRunner.call_lookup("mylookup", plugin,
          [JSON::Any.new(BIG)], NO_KWARGS, NO_KWARGS)
      end
      ex.unavailable?.must_equal(true)
      ex.message.to_s.must_match(/produced no result/)
      ex.message.to_s.wont_match(/failed to spawn/)
    end
  ensure
    FileUtils.rm_r(root) if root
  end

  it "reports an action wrapper that ran and died as produced-no-result, not a spawn failure" do
    root = File.join(Dir.tempdir, "krikri-spawncls-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(root)
    plugin = File.join(root, "myaction.py")
    File.write(plugin, "# test plugin")
    counter = File.join(root, "spawn-counter")
    File.write(counter, "")

    with_fake_python3(counter) do
      ex = assert_raises(Krikri::PythonActionRunner::ActionUnavailableError) do
        Krikri::PythonActionRunner.run_action(plugin, "myaction",
          {"x" => JSON::Any.new(BIG)}, "local", "localhost", nil,
          nil, false, nil, false, NO_KWARGS)
      end
      ex.unavailable?.must_equal(true)
      ex.message.to_s.must_match(/produced no result/)
      ex.message.to_s.wont_match(/failed to spawn/)
    end
  ensure
    FileUtils.rm_r(root) if root
  end
end
