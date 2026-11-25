require "../minitest_helper"
require "file_utils"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# Ansible's gather_facts action runs its fact module under async_wrapper
# whenever `parallel:` (or the ansible_facts_parallel var, which wins)
# resolves truthy, and async_wrapper's finished job file is never removed
# afterwards: the action polls with async_status' STATUS mode, and only
# `mode: cleanup` unlinks. kpg's host-state oracle compared the two hosts
# after a parallel gather and found the file only on real ansible's
# (issue #1808); a later async_status: on the jid real reports relies on
# the same file.
describe "parallel gather_facts job file (gather_facts_async_job_file_test.cr)" do
  # AsyncJobs.dir resolves ANSIBLE_ASYNC_DIR/HOME in-process, so the
  # override has to be process-quiesced rather than merely serial (a
  # non-serial test keeps reading it - issue #1191).
  exclusive!

  private def in_temp_async_dir(&)
    original = ENV["ANSIBLE_ASYNC_DIR"]?
    dir = File.join(Dir.tempdir, "krikri-facts-gather-async-job-#{Random::Secure.hex(4)}")
    ENV["ANSIBLE_ASYNC_DIR"] = dir
    yield dir
  ensure
    original ? (ENV["ANSIBLE_ASYNC_DIR"] = original) : ENV.delete("ANSIBLE_ASYNC_DIR")
    FileUtils.rm_rf(dir) if dir
  end

  private def config(params = {} of String => JSON::Any, async : Bool = true) : JSON::Any
    values = {} of String => JSON::Any
    values["_first_gather"] = JSON::Any.new("false")
    values["_module_name"] = JSON::Any.new("ansible.builtin.gather_facts")
    values["_ansible_gather_async"] = JSON::Any.new("true") if async
    params.each { |key, value| values[key] = value }
    JSON.parse({
      "host"   => {"name" => "testhost", "user" => "root", "port" => 22},
      "vars"   => {} of String => JSON::Any,
      "params" => values,
    }.to_json)
  end

  private def job_files(dir : String) : Array(String)
    return [] of String unless Dir.exists?(dir)
    Dir.children(dir).map { |name| File.join(dir, name) }.select { |path| File.file?(path) }
  end

  it "leaves the module's facts payload in the async dir, 0644" do
    in_temp_async_dir do |dir|
      result = JSON.parse(Krikri::FactsGatherer.run(config))

      jobs = job_files(dir)
      jobs.size.must_equal(1, "async_wrapper leaves exactly one job file for the one fact module the action runs")
      path = jobs.first
      # async_wrapper's own file name: the action's "j<digits>" jid plus
      # the pid of the process async_wrapper forked.
      File.basename(path).must_match(/\Aj\d+\.\d+\z/)
      mode = File.info(path).permissions.value & 0o777
      mode.must_equal(0o644, "async_wrapper's worker daemonizes under umask 022, unlike the 0600 of an async: task's own sidecars")
      payload = JSON.parse(File.read(path))
      payload.as_h.keys.must_equal(["ansible_facts"], "the action's failed/changed backfill and discovery stamp are controller-side")
      payload["ansible_facts"].as_h.wont_be_empty
      payload["ansible_facts"].as_h["ansible_system"]?.must_equal(result["ansible_facts"].as_h["ansible_system"]?)
    end
  end

  it "leaves no job file for a serial gather" do
    in_temp_async_dir do |dir|
      result = JSON.parse(Krikri::FactsGatherer.run(config(async: false)))

      expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
      job_files(dir).must_be_empty
    end
  end

  it "names the rejected-argument job file with the jid it reports" do
    in_temp_async_dir do |dir|
      result = JSON.parse(Krikri::FactsGatherer.run(config({"parallel_bogus" => JSON::Any.new("true")})))

      failed = result["failed_modules"].as_h["ansible.legacy.setup"].as_h
      jid = failed["ansible_job_id"].as_s
      path = File.join(dir, jid)
      File.exists?(path).must_equal(true, "real reports the jid of the job file async_wrapper wrote for the same gather")
      (File.info(path).permissions.value & 0o777).must_equal(0o644)
      # async_wrapper writes the module's own fail_json, which is what an
      # async_status: on the reported jid reads back.
      payload = JSON.parse(File.read(path))
      payload.as_h.keys.must_equal(["failed", "msg"])
      payload["failed"].as_bool.must_equal(true)
      payload["msg"].as_s.must_equal(
        "Unsupported parameters for (ansible.legacy.setup) module: parallel_bogus. " \
        "Supported parameters include: fact_path, filter, gather_subset, gather_timeout.")
    end
  end
end
