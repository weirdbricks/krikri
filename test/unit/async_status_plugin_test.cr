require "../minitest_helper"
require "file_utils"

# Pins plugins/async_status.cr's result shapes against
# ansible.builtin.async_status's module source (async_status.py):
# the AnsibleModule fixed wording "missing required arguments:" (plural,
# even for one param), and the not-found fail_json call's exact kwargs
# (msg: "could not find job", ansible_job_id, started=True, finished=True
# - booleans since ansible-core 2.19). Runs the compiled plugin binary
# via PluginSpecHelper, the same way PluginManager invokes it.
#
# The async dir the plugin binary resolves from HOME in its own process
# (ANSIBLE_ASYNC_DIR is unset here, so the HOME default applies). Specs that
# need a home other than the real one pass `env: {"HOME" => home}` to
# PluginSpecHelper.run and compute their own paths under that home; this
# process's ENV is never touched, because a non-serial test keeps reading it
# concurrently (issue #1191).
private def spec_home : String
  ENV["HOME"]? || "/tmp"
end

private def async_dir(home : String) : String
  File.join(home, ".ansible_async")
end

private def status_path(home : String, jid : String) : String
  File.join(async_dir(home), jid)
end

private def config_path(home : String, jid : String) : String
  File.join(async_dir(home), "#{jid}.config.json")
end

describe "async_status plugin result shapes" do
  serial! # mutates process-global state (ENV / engine settings)

  it "phrases a missing jid like AnsibleModule's fixed wording (plural 'arguments')" do
    result = PluginSpecHelper.run("async_status", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: jid")
  end

  it "matches Ansible's exact not-found result shape" do
    jid = "#{Time.utc.to_unix}.#{Random::Secure.hex(6)}"
    begin
      result = PluginSpecHelper.run("async_status", {"jid" => jid})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("could not find job")
      result["ansible_job_id"].as_s.must_equal(jid)
      result["started"].as_bool.must_equal(true)
      result["finished"].as_bool.must_equal(true)
    ensure
      File.delete?(status_path(spec_home, jid))
      File.delete?(config_path(spec_home, jid))
    end
  end

  # Regression for issue #943: the async_status ACTION plugin pre-seeds the
  # result with the job-file path before calling the module, using
  # `results_file` in status mode but `erased` in cleanup mode
  # (action/async_status.py). The module's not-found fail_json merges over
  # that, so cleanup on a jid that never ran reports `erased`, never
  # `results_file` - live-verified against ansible-playbook 2.21.6.
  it "reports erased (not results_file) for a cleanup on a never-started jid" do
    jid = "#{Time.utc.to_unix}.#{Random::Secure.hex(6)}"
    begin
      result = PluginSpecHelper.run("async_status", {"jid" => jid, "mode" => "cleanup"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("could not find job")
      result["ansible_job_id"].as_s.must_equal(jid)
      result["started"].as_bool.must_equal(true)
      result["finished"].as_bool.must_equal(true)
      result["erased"].as_s.must_equal(status_path(spec_home, jid))
      result["results_file"]?.must_be_nil
    ensure
      File.delete?(status_path(spec_home, jid))
      File.delete?(config_path(spec_home, jid))
    end
  end

  # Regression: a traversal jid must be rejected before AsyncJobs joins it
  # into the async-dir path - status mode would otherwise read an arbitrary
  # controller-local file and mode: cleanup would delete one.
  it "rejects a path-traversal jid in status mode instead of probing the file" do
    traversal_jid = "../../../../etc/passwd"

    result = PluginSpecHelper.run("async_status", {"jid" => traversal_jid})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("invalid jid: #{traversal_jid}")
    result["ansible_job_id"].as_s.must_equal(traversal_jid)
  end

  it "rejects a path-traversal jid in cleanup mode without deleting anything" do
    # Home is pointed at a temp dir (same reason as the spec above) so the
    # traversal jid "../<sentinel>" would, if the validation were missing,
    # delete the sentinel - a real deletion proof that never risks a real
    # system file even on a broken build. Only the CHILD's HOME is
    # overridden (issue #1191).
    home = File.join(Dir.tempdir, "krikri-async-status-spec-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(async_dir(home))
    sentinel = File.join(home, "sentinel-#{Random::Secure.hex(4)}")
    File.write(sentinel, "still here")
    begin
      result = PluginSpecHelper.run("async_status", {"jid" => "../#{File.basename(sentinel)}", "mode" => "cleanup"},
        env: {"HOME" => home})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("invalid jid: ../#{File.basename(sentinel)}")
      File.exists?(sentinel).must_equal(true)
    ensure
      FileUtils.rm_r(home)
    end
  end

  it "rejects other jid shapes that are not simple job ids" do
    ["", "/etc/passwd", "..", "a/b", "a\\b", ".hidden", "jid with spaces"].each do |bad|
      result = PluginSpecHelper.run("async_status", {"jid" => bad})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.starts_with?("invalid jid:").must_equal(true)
    end
  end

  it "still reports a finished job's own result in status mode" do
    jid = "#{Time.utc.to_unix}.#{Random::Secure.hex(6)}"
    # A private home for the run so the job file this spec seeds and the
    # plugin's own resolution agree; only the CHILD's HOME is overridden
    # (issue #1191).
    home = File.join(Dir.tempdir, "krikri-async-status-spec-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(async_dir(home))
    begin
      File.write(File.join(async_dir(home), jid), {"finished" => 1, "changed" => true, "rc" => 0}.to_json)

      result = PluginSpecHelper.run("async_status", {"jid" => jid}, env: {"HOME" => home})

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      # ansible-core 2.19.11 normalizes started/finished to JSON
      # booleans (live-verified: a finished poll's registered var reads
      # finished=True), even when the underlying status file carried an
      # int 1.
      result["finished"].as_bool.must_equal(true)
      result["rc"].as_i.must_equal(0)
    ensure
      FileUtils.rm_r(home)
    end
  end

  # Regression for issue #922: ansible-core 2.19+'s controller validates each
  # module result against the task-result schema, and `finished` is a bool
  # field - a job file returning it as a JSON int (the pre-2.19 wire shape,
  # also what the kpg fixtures seed) warns and converts. The warning's block
  # text, obj dump and Origin: <unknown> are live-captured against 2.21.6
  # with the same seeded file.
  it "warns and converts a JSON-int finished like the controller schema check" do
    seeded = warn_case({"started" => 1, "finished" => 1})

    seeded["warnings"].as_a.size.must_equal(1)
    seeded["warnings"].as_a[0].as_s.must_equal(
      "Value for result key 'finished' of type int was converted to bool.\n" \
      "Origin: <unknown>\n" \
      "\n" \
      "1\n" \
      "\n" \
      "Values for result key 'finished' must be of type bool."
    )
    seeded["finished"].as_bool.must_equal(true)
  end

  it "warns for other non-bool finished types with ansible's type names and obj dumps" do
    warn_case({"started" => 1, "finished" => "yes"})["warnings"].as_a[0].as_s.must_equal(
      "Value for result key 'finished' of type str was converted to bool.\n" \
      "Origin: <unknown>\n" \
      "\n" \
      "yes\n" \
      "\n" \
      "Values for result key 'finished' must be of type bool."
    )
    warn_case({"started" => 1, "finished" => 1.5})["warnings"].as_a[0].as_s.must_equal(
      "Value for result key 'finished' of type float was converted to bool.\n" \
      "Origin: <unknown>\n" \
      "\n" \
      "1.5\n" \
      "\n" \
      "Values for result key 'finished' must be of type bool."
    )
    warn_case({"started" => 1, "finished" => {"a" => true}})["warnings"].as_a[0].as_s.must_equal(
      "Value for result key 'finished' of type dict was converted to bool.\n" \
      "Origin: <unknown>\n" \
      "\n" \
      "{'a': True}\n" \
      "\n" \
      "Values for result key 'finished' must be of type bool."
    )
    warn_case({"started" => 1, "finished" => [true, 1]})["warnings"].as_a[0].as_s.must_equal(
      "Value for result key 'finished' of type list was converted to bool.\n" \
      "Origin: <unknown>\n" \
      "\n" \
      "[True, 1]\n" \
      "\n" \
      "Values for result key 'finished' must be of type bool."
    )
  end

  # The module only returns the job file's own finished value when BOTH keys
  # exist: a file without `started` forces finished=True and one with
  # `started` but no `finished` forces False - both bools, so the controller
  # never warns. A null finished is the optional field's None - also silent.
  it "stays silent when the module would force a bool finished itself" do
    warn_case({"finished" => 1})["warnings"]?.must_be_nil
    warn_case({"started" => 1})["warnings"]?.must_be_nil
    warn_case({"started" => 1, "finished" => nil})["warnings"]?.must_be_nil
  end

  # Seeds a job file in a private async dir and runs the plugin binary
  # against it, returning the plugin's JSON result. The private home goes to
  # the CHILD only (issue #1191).
  private def warn_case(file : Hash) : JSON::Any
    jid = "#{Time.utc.to_unix}.#{Random::Secure.hex(6)}"
    home = File.join(Dir.tempdir, "krikri-async-status-spec-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(async_dir(home))
    begin
      File.write(File.join(async_dir(home), jid), file.merge({"ansible_job_id" => jid}).to_json)

      PluginSpecHelper.run("async_status", {"jid" => jid}, env: {"HOME" => home})
    ensure
      FileUtils.rm_r(home)
    end
  end
end
