require "../minitest_helper"
require "file_utils"

# Pins plugins/async_status.cr's result shapes against real
# ansible.builtin.async_status's module source (async_status.py):
# the AnsibleModule fixed wording "missing required arguments:" (plural,
# even for one param), and the not-found fail_json call's exact kwargs
# (msg: "could not find job", ansible_job_id, started=True, finished=True
# - booleans since ansible-core 2.19). Runs the compiled plugin binary
# via PluginSpecHelper, the same way PluginManager invokes it.
#
# The async dir is resolved at spec-run time (not via Krikri::AsyncJobs.dir)
# because other specs mutate ENV["HOME"], and the plugin binary resolves it
# from HOME in its own process at call time (ANSIBLE_ASYNC_DIR is unset
# here, so the HOME default applies).
private def async_dir : String
  File.join(ENV["HOME"]? || "/tmp", ".ansible_async")
end

private def status_path(jid : String) : String
  File.join(async_dir, jid)
end

private def config_path(jid : String) : String
  File.join(async_dir, "#{jid}.config.json")
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
      File.delete?(status_path(jid))
      File.delete?(config_path(jid))
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
    # system file even on a broken build.
    PluginSpecHelper::ENV_MUTEX.synchronize do
      original_home = ENV["HOME"]?
      home = File.join(Dir.tempdir, "krikri-async-status-spec-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(File.join(home, ".ansible_async"))
      ENV["HOME"] = home
      sentinel = File.join(home, "sentinel-#{Random::Secure.hex(4)}")
      File.write(sentinel, "still here")
      begin
        result = PluginSpecHelper.run("async_status", {"jid" => "../#{File.basename(sentinel)}", "mode" => "cleanup"})

        result["failed"].as_bool.must_equal(true)
        result["msg"].as_s.must_equal("invalid jid: ../#{File.basename(sentinel)}")
        File.exists?(sentinel).must_equal(true)
      ensure
        FileUtils.rm_r(home) if original_home != home
        original_home ? (ENV["HOME"] = original_home) : ENV.delete("HOME")
        File.delete?(sentinel)
      end
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
    # Some specs leave ENV["HOME"] pointing somewhere unwritable; point it
    # at our own temp dir for the duration so both this process and the
    # plugin subprocess resolve the same writable async dir, then restore.
    PluginSpecHelper::ENV_MUTEX.synchronize do
      original_home = ENV["HOME"]?
      home = File.join(Dir.tempdir, "krikri-async-status-spec-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(File.join(home, ".ansible_async"))
      ENV["HOME"] = home
      begin
        File.write(File.join(async_dir, jid), {"finished" => 1, "changed" => true, "rc" => 0}.to_json)

        result = PluginSpecHelper.run("async_status", {"jid" => jid})

        result["failed"]?.must_be_nil
        result["changed"].as_bool.must_equal(true)
        # ansible-core 2.19.11 normalizes started/finished to JSON
        # booleans (live-verified: a finished poll's registered var reads
        # finished=True), even when the underlying status file carried an
        # int 1.
        result["finished"].as_bool.must_equal(true)
        result["rc"].as_i.must_equal(0)
      ensure
        FileUtils.rm_r(home) if original_home != home
        original_home ? (ENV["HOME"] = original_home) : ENV.delete("HOME")
        File.delete?(status_path(jid))
        File.delete?(config_path(jid))
      end
    end
  end
end
