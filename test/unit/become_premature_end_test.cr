require "../minitest_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/host"

describe "Krikri::PluginManager.become_premature_end_result (become_premature_end_test.cr)" do
  it "words an empty-stdout sudo failure like ansible's become failure" do
    result = Krikri::PluginManager.become_premature_end_result("", "sudo: a password is required\n")
    result.must_be_instance_of(JSON::Any)
    result = result.as(JSON::Any)
    result["msg"].as_s.must_equal("Task failed: Premature end of stream waiting for become success.\n>>> Standard Error\nsudo: a password is required")
    result["_connection_failure"].as_bool.must_equal(true)
    result["failed"].as_bool.must_equal(true)
  end

  it "leaves a silent or output-bearing failure to the generic parse error" do
    Krikri::PluginManager.become_premature_end_result("", "").must_be_nil
    Krikri::PluginManager.become_premature_end_result("garbage", "sudo: boom").must_be_nil
  end
end

# Round-trip 350: whether the config write lands before sudo exits or
# the write hits EPIPE on an already-gone sudo is pure scheduling, so
# both tests below assert the RESULT both hands must share - never the
# broken-pipe shape, always the premature-end one.
#
# "ping" keeps this off the modules other suite runs stage as become
# binaries (their staged copies DO get exec'd; this resolve ends at the
# checkout's own plugins/ping source - which, with sudo refusing before
# exec, never runs at all). Nothing else in the suite stages ping for a
# local become, so this test's staged copy is its own.
private def become_epipe_sudo_spawnable? : Bool
  spawnable = true
  begin
    Process.run("sudo", ["-n", "--", "true"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
  rescue
    spawnable = false
  end
  spawnable
end

private def become_epipe_local_become(config : String) : JSON::Any
  host = Krikri::Host.new("localhost", "root", 22)
  host.vars["ansible_connection"] = JSON::Any.new("local")
  Krikri::PluginManager.execute_plugin(
    "ping",
    config,
    host,
    {} of String => JSON::Any,
    true,
    "krikri-spec-become-write-race",
  )
end

private def become_epipe_assert_failure(result : JSON::Any) : Nil
  result["failed"].as_bool.must_equal(true)
  result["_connection_failure"].as_bool.must_equal(true)
  msg = result["msg"].as_s
  msg.starts_with?("Task failed: Premature end of stream waiting for become success.\n>>> Standard Error\nsudo: ").must_equal(true)
  msg.includes?("Plugin execution failed").must_equal(false)
  msg.includes?("Broken pipe").must_equal(false)
end

describe "Krikri::PluginManager.execute_plugin local become early-exit (become_premature_end_test.cr)" do
  it "books a refusing sudo as the become failure when the config write lands first" do
    skip "sudo not installed here" unless become_epipe_sudo_spawnable?
    3.times do
      become_epipe_assert_failure(become_epipe_local_become(%({"params": {"data": "pong"}})))
    end
  end

  it "books it there too when sudo leaves before the whole config lands (the reported EPIPE hand)" do
    skip "sudo not installed here" unless become_epipe_sudo_spawnable?
    # A payload wider than the pipe buffer parks the writer mid-config
    # while the refusing sudo (a few ms to print its error and exit) beats
    # it to the exit; the writer then resumes into a closed read end and
    # raises EPIPE - the hand that used to surface as
    # "Plugin execution failed: write ... Broken pipe" instead of ansible's
    # become failure.
    become_epipe_assert_failure(become_epipe_local_become(%({"junk": "#{"x" * 262144}"})))
  end
end

# Issue #498: ansible validates a module's own arguments INSIDE the
# module - after the become escalation - so a local `become:` task with
# an unsupported parameter on a sudo-needs-a-password controller fails
# as the premature-end become failure, never as "Unsupported
# parameters". The executor skips its module-level argspec check exactly
# when the dispatch is doomed to hit the refusing sudo; both runs here
# go through the real binary end to end with a fake `sudo` earlier on
# the child's PATH (passed via Process.run's env, never the suite
# process's own ENV). The become_user is a name no suite host runs as,
# so become_needed? holds even under a root suite.
private def issue498_run_playbook(sudo_body : String) : String
  fake_bin = PluginSpecHelper.tmp_path("issue498-fake-bin")
  FileUtils.rm_rf(fake_bin)
  FileUtils.mkdir_p(fake_bin)
  sudo_path = File.join(fake_bin, "sudo")
  File.write(sudo_path, "#!/bin/sh\n#{sudo_body}\n")
  File.chmod(sudo_path, 0o755)
  playbook = File.tempname("issue498", ".yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      gather_facts: false
      become: true
      become_user: krikri-issue498-other
      tasks:
        - name: unsupported param under local become
          command:
            _raw_params: rpm --version
            warn: false
          ignore_errors: true
    YAML
  output = IO::Memory.new
  Process.run(
    File.join(PluginSpecHelper::PROJECT_ROOT, "bin", "krikri-playbook"),
    ["-i", File.join(PluginSpecHelper::PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini"), playbook],
    output: output, error: output,
    env: {"PATH" => "#{fake_bin}:#{ENV["PATH"]}"}
  )
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "executor module-argspec skip on a doomed local become (become_premature_end_test.cr)" do
  it "reports sudo's premature-end failure, not the argspec message" do
    out = issue498_run_playbook("echo 'sudo: a password is required' >&2\nexit 1")
    out.must_include("Premature end of stream waiting for become success")
    out.must_include("sudo: a password is required")
    out.includes?("Unsupported parameters").must_equal(false)
  end

  it "keeps the Unsupported parameters message when sudo would succeed" do
    out = issue498_run_playbook("exit 0")
    out.must_include("Unsupported parameters for (ansible.legacy.command) module: warn.")
  end
end

# Issue #986 (cloudweeb.apache_exporter live round): real ansible RAISES a
# become failure out of handler.run(), and task_executor.py's attempt loop
# only ever sees RETURNED results ("exceptions raised anywhere here bypass
# failed_when, `until` retries, intra-loop register/register-projections"),
# so an until:/retries: task runs ONCE - no FAILED - RETRYING line, no
# attempts key on the fatal result (live-verified vs 2.21.6 with the role's
# own `get_url` under `delegate_to: localhost` inheriting the play's
# become: true on a controller whose sudo needs a password). Same fake-sudo
# seam as the argspec test above, so this holds on hosts whose own sudo is
# passwordless.
private def issue986_run_playbook : String
  fake_bin = PluginSpecHelper.tmp_path("issue986-fake-bin")
  FileUtils.rm_rf(fake_bin)
  FileUtils.mkdir_p(fake_bin)
  sudo_path = File.join(fake_bin, "sudo")
  File.write(sudo_path, "#!/bin/sh\necho 'sudo: a password is required' >&2\nexit 1\n")
  File.chmod(sudo_path, 0o755)
  playbook = PluginSpecHelper.tmp_path("issue986-play.yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      gather_facts: false
      become: true
      become_user: krikri-issue986-other
      tasks:
        - name: download under until
          command:
            _raw_params: /bin/true
          register: dl
          until: dl is succeeded
          retries: 2
          delay: 1
    YAML
  output = IO::Memory.new
  Process.run(
    File.join(PluginSpecHelper::PROJECT_ROOT, "bin", "krikri-playbook"),
    ["-i", File.join(PluginSpecHelper::PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini"), playbook],
    output: output, error: output,
    env: {"PATH" => "#{fake_bin}:#{ENV["PATH"]}"}
  )
  output.to_s
end

describe "until: on a raised become failure (become_premature_end_test.cr)" do
  it "runs the task once: no FAILED - RETRYING line and no attempts key" do
    out = issue986_run_playbook
    out.must_include("Premature end of stream waiting for become success")
    out.wont_include("RETRYING")
    out.wont_include("attempts")
  end
end
