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

  # ansible-core 2.19 attaches an ErrorSummary-derived `exception` to every
  # controller-fatal task result - "(traceback unavailable)" with tracebacks
  # disabled - which survives into registered vars (a debug: of the registered
  # result prints it) while the fatal dump strips it (live-verified vs
  # 2.19.11; issue #546, laniakea.galaxy_tools).
  it "carries ansible's exception key on the chown failure result" do
    result = Krikri::PluginManager.become_chown_failure_result(1, "sudo: unknown user nosuchuser\n", "nosuchuser", "root")
    result.must_be_instance_of(JSON::Any)
    result.as(JSON::Any)["exception"].as_s.must_equal("(traceback unavailable)")
  end

  it "carries the same exception key on the probe-detected chown failure result" do
    local = Krikri::PluginManager.local_username
    skip "no local username on this host" unless local
    result = Krikri::PluginManager.become_chown_failure_local(true, "nosuchuser_xyz_1972", [local])
    result.as(JSON::Any)["exception"].as_s.must_equal("(traceback unavailable)")
  end

  it "hides the probe failure's marker in the display but keeps it for failed_when" do
    source = File.read("src/krikri/task_executor/result_display.cr")
    source.must_match(/BecomeMessages::CHOWN_FAILURE/)
    local = Krikri::PluginManager.local_username
    skip "no local username on this host" unless local
    result = Krikri::PluginManager.become_chown_failure_local(true, "nosuchuser_xyz_1972", [local])
    result.as(JSON::Any)["_connection_failure"].as_bool.must_equal(true)
  end

  it "probes whether root can chown a scratch file to the become_user, like _fixup_perms2" do
    script = Krikri::PluginManager.chown_probe_script("cve_user")
    script.must_match(/mktemp/)
    script.must_match(/chown cve_user "\$t"/)
    script.must_match(/exit \$rc/)
  end

  # Issue #986: _fixup_perms2 RAISES this in ansible, so an until:/retries:
  # task is never retried and never gets an attempts key - the marker is
  # what run_until_retries escapes on, next to the action-level and
  # finalization ones.
  it "marks the unknown-become_user chown failure as a raise escape" do
    result = Krikri::PluginManager.become_chown_failure_result(1, "sudo: unknown user nosuchuser\n", "nosuchuser", "root")
    result.as(JSON::Any)["_ansible_raise_escape"].as_bool.must_equal(true)
  end

  it "marks the probe-detected chown failure as a raise escape too" do
    local = Krikri::PluginManager.local_username
    skip "no local username on this host" unless local
    result = Krikri::PluginManager.become_chown_failure_local(true, "nosuchuser_xyz_1972", [local])
    result.as(JSON::Any)["_ansible_raise_escape"].as_bool.must_equal(true)
  end

  # Issue #1972's round: the Rocky target runs sudo 1.9.5, whose line is
  # "sudo: unknown user: vagrant" (coloned), while the Ubuntu controller's
  # 1.9.16 omits the colon - the old matcher only knew the colonless form,
  # so the round fell through to the generic "Plugin execution failed on
  # remote". sudo-rs (Ubuntu 26 runners) words it a third way.
  it "words every sudo build's spelling of an unknown user as the chown failure" do
    ["sudo: unknown user nosuchuser",
     "sudo: unknown user: nosuchuser",
     "sudo: user 'nosuchuser' not found"].each do |line|
      result = Krikri::PluginManager.become_chown_failure_result(1, "#{line}\n", "nosuchuser", "root")
      result.must_be_instance_of(JSON::Any)
      result.as(JSON::Any)["msg"].as_s.must_equal("Task failed: #{Krikri::PluginManager::BECOME_CHOWN_FAILURE}")
    end
  end

  it "keys the chown wording on ansible's admin_users list, not a hardcoded root" do
    # _fixup_perms2 raises for any connection user in admin_users.
    result = Krikri::PluginManager.become_chown_failure_result(1, "sudo: unknown user nosuchuser\n", "nosuchuser", "deploy", ["deploy"])
    result.must_be_instance_of(JSON::Any)
    # ... and leaves a user outside it to the ACL ladder's own failure.
    Krikri::PluginManager.become_chown_failure_result(1, "sudo: unknown user nosuchuser\n", "nosuchuser", "root", ["deploy"]).must_be_nil
  end

  # _fixup_perms2 chowns the module payload to the become_user on a local
  # connection too, as the INVOKING user; a user that does not exist cannot
  # be chowned to, so ansible fails the task before any module runs. Krikri
  # used to spawn `sudo -u <user>` and book sudo's refusal as a premature
  # become end (issue #1972's local leg).
  it "books a nonexistent become_user on a local connection like _fixup_perms2" do
    local = Krikri::PluginManager.local_username
    skip "no local username on this host" unless local
    result = Krikri::PluginManager.become_chown_failure_local(true, "nosuchuser_xyz_1972", [local])
    result.must_be_instance_of(JSON::Any)
    result.as(JSON::Any)["msg"].as_s.must_equal("Task failed: #{Krikri::PluginManager::BECOME_CHOWN_FAILURE}")
  end

  it "leaves a non-admin invoking user's local become to sudo, as ansible leaves it" do
    local = Krikri::PluginManager.local_username
    skip "no local username on this host" unless local
    skip "the suite is running as an admin user" if Krikri::AdminUsers::DEFAULT.includes?(local)
    Krikri::PluginManager.become_chown_failure_local(true, "nosuchuser_xyz_1972", Krikri::AdminUsers::DEFAULT).must_be_nil
  end

  it "does not book a local become to a user that exists" do
    local = Krikri::PluginManager.local_username
    skip "no local username on this host" unless local
    skip "the suite is running as root" if local == "root"
    # root always exists, so the existence gate - not become_needed? - is
    # what keeps this nil.
    Krikri::PluginManager.become_chown_failure_local(true, "root", [local]).must_be_nil
  end

  # chown refuses a missing user exactly like an ownership change it may
  # not make; _fixup_perms2 raises for both, so the probe must count both.
  it "counts chown's refusal for a missing user as the same refusal" do
    Krikri::PluginManager.become_chown_refused?(1).must_equal(true)
    Krikri::PluginManager.become_chown_refused?(255).must_equal(false)
    Krikri::PluginManager.become_chown_refused?(0).must_equal(false)
  end
end
