require "../spec_helper"

# Perf items 1-3 - drives the REAL
# compiled `.fat-plugin --daemon` binary as a local subprocess (no SSH
# involved at all), the same "exercise the real entrypoint, not a
# reimplementation of it" spirit `PluginSpecHelper` already uses for
# one-shot plugin binaries. This is genuine automated coverage of the
# framing/dispatch protocol `ssh_manager.cr`'s `daemon_send` speaks over
# a real SSH session - only the transport (a local pipe instead of SSH)
# differs, the wire protocol itself is identical.
private def daemon_send(process : Process, module_name : String, config : Hash) : JSON::Any
  request = {"module" => module_name, "config" => config}.to_json
  bytes = request.to_slice
  process.input.write_bytes(bytes.size.to_u32, IO::ByteFormat::BigEndian)
  process.input.write(bytes)
  process.input.flush

  length = process.output.read_bytes(UInt32, IO::ByteFormat::BigEndian)
  response = Bytes.new(length)
  process.output.read_fully(response)
  JSON.parse(String.new(response))
end

# Item 3's batch request shape: one frame carrying a LIST of steps,
# answered with one frame of index-keyed results.
private def daemon_batch(process : Process, steps : Array(Hash(String, JSON::Any))) : Hash(String, JSON::Any)
  request = {"batch" => steps}.to_json
  bytes = request.to_slice
  process.input.write_bytes(bytes.size.to_u32, IO::ByteFormat::BigEndian)
  process.input.write(bytes)
  process.input.flush

  length = process.output.read_bytes(UInt32, IO::ByteFormat::BigEndian)
  response = Bytes.new(length)
  process.output.read_fully(response)
  JSON.parse(String.new(response))["results"].as_h
end

private def batch_step(raw_command : String, ignore_errors : Bool = false) : Hash(String, JSON::Any)
  config = {
    "host"   => {"name" => "localhost", "user" => ENV["USER"]? || "root", "port" => 22},
    "vars"   => {"ansible_connection" => "local"},
    "params" => {"_raw_params" => raw_command},
  }
  {
    "module"        => JSON::Any.new("command"),
    "config"        => JSON.parse(config.to_json),
    "ignore_errors" => JSON::Any.new(ignore_errors),
  }
end

describe "fat plugin binary --daemon mode" do
  daemon_binary = File.join(PluginSpecHelper::PLUGINS_DIR, ".fat-plugin")

  # Perf item 2. `facts` was the one real
  # remote module missing from this binary's dispatch table, so it was
  # explicitly held off the daemon path (DAEMON_INELIGIBLE_PLUGINS) -
  # otherwise every fact gather, the one task that runs on every host in
  # every play, would have hit the "unknown plugin" fallback. This is
  # the check that the exclusion is genuinely no longer needed: a real
  # `--daemon` process must answer a facts request with real facts, and
  # must still serve an ordinary module afterwards on the same pipe.
  # Perf item 3. Batching and the daemon
  # used to be mutually exclusive PER TASK: a batched group went out as
  # a fresh ssh + bash + base64 script and the daemon served only solo
  # tasks, so every task took one optimization and forfeited the other.
  #
  # What has to hold for that to be safe is that the two transports are
  # indistinguishable from the result: same fail-fast rule, same
  # ignore_errors override, and the same "an absent index never ran"
  # contract BatchScript.parse documents. Those are what is pinned here,
  # against the REAL compiled daemon rather than a reimplementation.
  it "runs a batch of steps in one request, in order" do
    pending! "fat plugin binary not built (run ./build.sh first)" unless File.exists?(daemon_binary)

    process = Process.new(daemon_binary, ["--daemon"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)

    begin
      results = daemon_batch(process, [
        batch_step("echo one"),
        batch_step("echo two"),
        batch_step("echo three"),
      ])

      results.size.should eq(3)
      results["0"]["stdout"].as_s.should eq("one")
      results["1"]["stdout"].as_s.should eq("two")
      results["2"]["stdout"].as_s.should eq("three")
    ensure
      process.input.close rescue nil
      process.wait rescue nil
    end
  end

  it "stops a batch at the first failing step, exactly as the script transport does" do
    pending! "fat plugin binary not built (run ./build.sh first)" unless File.exists?(daemon_binary)

    process = Process.new(daemon_binary, ["--daemon"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)

    begin
      results = daemon_batch(process, [
        batch_step("echo a"),
        batch_step("exit 7"),
        batch_step("echo never"),
      ])

      results["0"]["stdout"].as_s.should eq("a")
      results["1"]["failed"].as_bool.should be_true
      # Absent, not present-and-failed: the step genuinely never ran, and
      # that is how the caller distinguishes the two.
      results.has_key?("2").should be_false
    ensure
      process.input.close rescue nil
      process.wait rescue nil
    end
  end

  it "lets an ignore_errors step fail without stopping the batch" do
    pending! "fat plugin binary not built (run ./build.sh first)" unless File.exists?(daemon_binary)

    process = Process.new(daemon_binary, ["--daemon"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)

    begin
      results = daemon_batch(process, [
        batch_step("echo a"),
        batch_step("exit 7", ignore_errors: true),
        batch_step("echo after"),
      ])

      results.size.should eq(3)
      results["1"]["failed"].as_bool.should be_true
      results["2"]["stdout"].as_s.should eq("after")
    ensure
      process.input.close rescue nil
      process.wait rescue nil
    end
  end

  it "keeps serving solo requests on the same process after a batch" do
    pending! "fat plugin binary not built (run ./build.sh first)" unless File.exists?(daemon_binary)

    process = Process.new(daemon_binary, ["--daemon"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)

    begin
      daemon_batch(process, [batch_step("echo batched")])

      base_config = {"host" => {"name" => "localhost", "user" => ENV["USER"]? || "root", "port" => 22}, "vars" => {"ansible_connection" => "local"}}
      solo = daemon_send(process, "command", base_config.merge({"params" => {"_raw_params" => "echo solo"}}))
      solo["stdout"]?.try(&.as_s).should eq("solo")
    ensure
      process.input.close rescue nil
      process.wait rescue nil
    end
  end

  it "serves facts over the daemon, on the same process as any other module" do
    pending! "fat plugin binary not built (run ./build.sh first)" unless File.exists?(daemon_binary)

    process = Process.new(daemon_binary, ["--daemon"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)

    begin
      base_config = {"host" => {"name" => "localhost", "user" => ENV["USER"]? || "root", "port" => 22}, "vars" => {} of String => String}

      facts = daemon_send(process, "facts", base_config.merge({"params" => {} of String => String}))
      facts["failed"]?.try(&.as_bool).should be_false
      gathered = facts["ansible_facts"].as_h
      gathered["ansible_system"]?.should_not be_nil
      gathered["ansible_distribution"]?.should_not be_nil
      # Not the "unknown plugin: facts" shape the exclusion existed to
      # avoid - that one carries a msg and no ansible_facts at all.
      facts["msg"]?.should be_nil

      # gather_subset still reaches the gatherer through the wire config.
      minimal = daemon_send(process, "facts", base_config.merge({"params" => {"gather_subset" => "min"}}))
      minimal["ansible_facts"].as_h.size.should be < gathered.size

      # One daemon, both kinds of module.
      after = daemon_send(process, "command", base_config.merge({"params" => {"_raw_params" => "echo after-facts"}}))
      after["stdout"]?.try(&.as_s).should eq("after-facts")
    ensure
      process.input.close rescue nil
      process.wait rescue nil
    end
  end

  it "serves multiple requests over the SAME long-lived process, matching one-shot output" do
    pending! "fat plugin binary not built (run ./build.sh first)" unless File.exists?(daemon_binary)

    process = Process.new(daemon_binary, ["--daemon"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)

    begin
      base_config = {"host" => {"name" => "localhost", "user" => ENV["USER"]? || "root", "port" => 22}, "vars" => {} of String => String}

      first = daemon_send(process, "command", base_config.merge({"params" => {"_raw_params" => "echo daemon-one"}}))
      first["stdout"]?.try(&.as_s).should eq("daemon-one")
      first["failed"]?.try(&.as_bool).should be_false

      # A SECOND request over the identical process/pipe - the whole
      # point of the daemon: no new process spawned between these two
      # calls, unlike the one-shot path.
      second = daemon_send(process, "command", base_config.merge({"params" => {"_raw_params" => "echo daemon-two"}}))
      second["stdout"]?.try(&.as_s).should eq("daemon-two")

      # Matches what the equivalent one-shot invocation produces for the
      # identical input - the daemon path must be behaviorally
      # transparent, not just independently "working".
      one_shot = PluginSpecHelper.run("command", {"_raw_params" => "echo daemon-one"})
      one_shot["stdout"]?.try(&.as_s).should eq(first["stdout"]?.try(&.as_s))
    ensure
      process.input.close rescue nil
      process.wait
    end
  end

  it "returns a graceful JSON failure (not a crash) for an unrecognized module name, and keeps serving after it" do
    pending! "fat plugin binary not built (run ./build.sh first)" unless File.exists?(daemon_binary)

    process = Process.new(daemon_binary, ["--daemon"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)

    begin
      bad = daemon_send(process, "no_such_module", {"host" => {"name" => "localhost"}, "params" => {} of String => String})
      bad["failed"]?.try(&.as_bool).should be_true
      bad["msg"]?.to_s.should contain("unknown plugin")

      # One bad request must not have killed the daemon - the SAME
      # process still answers a real request afterward.
      ok = daemon_send(process, "command", {"host" => {"name" => "localhost", "user" => ENV["USER"]? || "root", "port" => 22}, "vars" => {} of String => String, "params" => {"_raw_params" => "echo still-alive"}})
      ok["stdout"]?.try(&.as_s).should eq("still-alive")
    ensure
      process.input.close rescue nil
      process.wait
    end
  end

  it "exits cleanly when stdin is closed" do
    pending! "fat plugin binary not built (run ./build.sh first)" unless File.exists?(daemon_binary)

    process = Process.new(daemon_binary, ["--daemon"],
      input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)

    process.input.close
    status = process.wait
    status.exit_code.should eq(0)
  end
end
