require "../spec_helper"
require "file_utils"

# Pins plugins/async_status.cr's result shapes against real
# ansible.builtin.async_status's module source (async_status.py):
# the AnsibleModule fixed wording "missing required arguments:" (plural,
# even for one param), and the not-found fail_json call's exact kwargs
# (msg: "could not find job", ansible_job_id, started=True, finished=True
# - booleans since ansible-core 2.19). Runs the compiled plugin binary
# via PluginSpecHelper, the same way PluginManager invokes it.
#
# The async dir is resolved at spec-run time (not via Krikri::AsyncJobs::DIR,
# a require-time constant) because other specs mutate ENV["HOME"], and the
# plugin binary resolves it from HOME in its own process at startup.
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
  it "phrases a missing jid like AnsibleModule's fixed wording (plural 'arguments')" do
    result = PluginSpecHelper.run("async_status", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: jid")
  end

  it "matches real Ansible's exact not-found result shape" do
    jid = "#{Time.utc.to_unix}.#{Random::Secure.hex(6)}"
    begin
      result = PluginSpecHelper.run("async_status", {"jid" => jid})

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_false
      result["msg"].as_s.should eq("could not find job")
      result["ansible_job_id"].as_s.should eq(jid)
      result["started"].as_bool.should be_true
      result["finished"].as_bool.should be_true
    ensure
      File.delete?(status_path(jid))
      File.delete?(config_path(jid))
    end
  end

  it "still reports a finished job's own result in status mode" do
    jid = "#{Time.utc.to_unix}.#{Random::Secure.hex(6)}"
    # Some specs leave ENV["HOME"] pointing somewhere unwritable; point it
    # at our own temp dir for the duration so both this process and the
    # plugin subprocess resolve the same writable async dir, then restore.
    original_home = ENV["HOME"]?
    home = File.join(Dir.tempdir, "krikri-async-status-spec-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(File.join(home, ".ansible_async"))
    ENV["HOME"] = home
    begin
      File.write(File.join(async_dir, jid), {"finished" => 1, "changed" => true, "rc" => 0}.to_json)

      result = PluginSpecHelper.run("async_status", {"jid" => jid})

      result["failed"]?.should be_nil
      result["changed"].as_bool.should be_true
      result["finished"].as_i.should eq(1)
      result["rc"].as_i.should eq(0)
    ensure
      FileUtils.rm_r(home) if original_home != home
      original_home ? (ENV["HOME"] = original_home) : ENV.delete("HOME")
      File.delete?(status_path(jid))
      File.delete?(config_path(jid))
    end
  end
end
