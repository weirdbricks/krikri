require "../minitest_helper"
require "../../src/krikri/process_spawn_retry"

# Regression coverage for src/krikri/process_spawn_retry.cr: the kernel
# refuses to exec a file that any process holds open for writing (ETXTBSY,
# "Text file busy"), so a spawn racing another fiber's inherited write fd
# used to fail outright. Holding the write fd here makes the race
# deterministic: the first attempt ALWAYS gets ETXTBSY, and only the retry
# can succeed once the closing fiber lets go.
private def spawn_retry_script(dir : String) : String
  Dir.mkdir_p(dir)
  path = File.join(dir, "spawn-retry-script")
  File.write(path, "#!/bin/sh\necho spawned\n")
  File.chmod(path, 0o755)
  path
end

describe "Process spawn ETXTBSY retry" do
  it "retries until the concurrent writer closes the executable" do
    path = spawn_retry_script(PluginSpecHelper.tmp_path("spawn_retry_spec"))

    writer = File.open(path, "a")
    begin
      spawn do
        sleep 12.milliseconds
        writer.close
      end

      output = IO::Memory.new
      status = Process.run(path, output: output)

      status.success?.must_equal(true)
      output.to_s.must_equal("spawned\n")
    ensure
      writer.close
    end
  end

  it "re-raises the original ETXTBSY error once the retry budget is spent" do
    path = spawn_retry_script(PluginSpecHelper.tmp_path("spawn_retry_exhausted_spec"))

    writer = File.open(path, "a")
    begin
      started = Time.instant
      ex = assert_raises(IO::Error) { Process.run(path) }
      elapsed = (Time.instant - started).total_milliseconds

      ex.os_error.must_equal(Errno::ETXTBSY)
      ex.message.to_s.includes?("Text file busy").must_equal(true)
      # 10 + 20 + 40 + 80ms of backoff before the fifth attempt gives up.
      (elapsed >= 140.0).must_equal(true)
    ensure
      writer.close
    end
  end
end
