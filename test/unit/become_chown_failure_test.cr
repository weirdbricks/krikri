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
end
