require "../minitest_helper"
require "../../src/krikri/plugin_manager"

describe "Krikri::PluginManager.become_chown_failure_result (become_chown_failure_test.cr)" do
  it "words an unknown become_user as ansible's _fixup_perms2 task failure" do
    result = Krikri::PluginManager.become_chown_failure_result(1, "sudo: unknown user nosuchuser\nsudo: a password is required\n", "nosuchuser", "root")
    result.must_be_instance_of(JSON::Any)
    result = result.as(JSON::Any)
    result["msg"].as_s.must_equal("Task failed: Failed to change ownership of the temporary files Ansible (via chmod nor setfacl) needs to create despite connecting as a privileged user. Unprivileged become user would be unable to read the file.")
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["_connection_failure"]?.must_be_nil
  end

  it "leaves a non-root connection user to the generic parse error" do
    Krikri::PluginManager.become_chown_failure_result(1, "sudo: unknown user nosuchuser\n", "nosuchuser", "deploy").must_be_nil
  end

  it "leaves a stderr naming a different user to the generic parse error" do
    Krikri::PluginManager.become_chown_failure_result(1, "sudo: unknown user otheruser\n", "nosuchuser", "root").must_be_nil
  end

  it "leaves a zero exit code to the generic parse error" do
    Krikri::PluginManager.become_chown_failure_result(0, "sudo: unknown user nosuchuser\n", "nosuchuser", "root").must_be_nil
  end

  it "hides the probe failure's marker in the display but keeps it for failed_when" do
    source = File.read("src/krikri/task_executor/result_display.cr")
    source.must_match(/BECOME_CHOWN_FAILURE/)
    plugin_source = File.read("src/krikri/plugin_manager.cr")
    plugin_source.must_match(/"_connection_failure" => true,\n\s+\}\.to_json\)\n\s+end\n\n\s+private def self\.user_exists_remote/)
  end

  it "probes whether root can chown a scratch file to the become_user, like _fixup_perms2" do
    script = Krikri::PluginManager.chown_probe_script("cve_user")
    script.must_match(/mktemp/)
    script.must_match(/chown cve_user "\$t"/)
    script.must_match(/exit \$rc/)
  end
end
