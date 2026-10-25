require "../minitest_helper"

# Issue #352 (guidugli.firewall): a `when:` on a task with delegate_to:
# evaluates ansible's TaskExecutor->PlayContext.update_vars seeding - the
# connection magic vars (ansible_connection included) are set from the
# DELEGATE's connection, but only when the task vars don't already carry
# one. So on an origin host with no explicit ansible_connection, a
# delegate_to: localhost task's `when: ansible_connection | default('ssh')
# in ['ssh','paramiko']` guard (the role's own detect_sshd_port prologue)
# sees the delegate's "local" and SKIPS - while an origin whose inventory
# entry explicitly pins ansible_connection=ssh keeps that value and the
# guarded task still runs. krikri used to seed the magic var from the
# ORIGIN's connection instead, so the guarded wait_for prologue ran
# (and failed) on every plain SSH host where Ansible skips it.
#
# The pre-upload pass is pinned here too, same bug family: a delegate_to:
# task's module never dispatches through the origin's connection, so its
# binary must not be eagerly uploaded to (and its transport failure must
# not pre-mark UNREACHABLE on) the origin - Ansible has no eager upload
# at all and the guarded task simply skips.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_playbook(inventory : String, yaml : String) : {Process::Status, String}
  dir = PluginSpecHelper.tmp_path("issue-352")
  FileUtils.mkdir_p(dir)
  inv = File.join(dir, "inv.ini")
  File.write(inv, inventory)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inv, playbook], output: output, error: output)
  {status, output.to_s}
end

describe "delegated task's ansible_connection magic var (issue #352)" do
  it "skips a delegate_to: localhost task guarded on ssh when the origin carries no explicit ansible_connection" do
    status, output = run_playbook(
      "h1 ansible_host=x.invalid\n",
      <<-YAML
        - hosts: h1
          gather_facts: false
          tasks:
            - name: guidugli.firewall's own guard shape
              command: "true"
              delegate_to: localhost
              when: ansible_connection | default('ssh') in ['ssh', 'paramiko']
            - name: delegate-derived local connection runs
              command: "touch #{PluginSpecHelper.tmp_path("issue-352")}/ran-local"
              delegate_to: localhost
              when: ansible_connection == 'local'
        YAML
    )

    status.exit_code.must_equal(0)
    # The guarded task never reaches a dispatch: no ssh attempt against the
    # origin, no unreachable booking - the plain `skipping:` line only.
    output.must_include("skipping: [h1]")
    output.wont_include("UNREACHABLE")
    output.wont_include("Failed to connect to the host via ssh")
    # The second task saw the DELEGATE's connection (local) and ran on it.
    output.must_include("changed: [h1 -> localhost]")
    output.must_match(/h1\s*: ok=1\s+changed=1\s+unreachable=0\s+failed=0\s+skipped=1/)
    File.exists?("#{PluginSpecHelper.tmp_path("issue-352")}/ran-local").must_equal(true)
  ensure
    FileUtils.rm_rf("#{PluginSpecHelper.tmp_path("issue-352")}/ran-local") if PluginSpecHelper.tmp_path("issue-352") && Dir.exists?(PluginSpecHelper.tmp_path("issue-352"))
  end

  it "keeps the origin's explicit ansible_connection=ssh for a delegated task's when: and still runs it on the delegate" do
    status, output = run_playbook(
      "h1 ansible_host=x.invalid ansible_connection=ssh\n",
      <<-YAML
        - hosts: h1
          gather_facts: false
          tasks:
            - name: origin's explicit ssh survives delegation in the task vars
              command: "touch #{PluginSpecHelper.tmp_path("issue-352")}/ran-ssh-origin"
              delegate_to: localhost
              when: ansible_connection | default('ssh') in ['ssh', 'paramiko']
        YAML
    )

    status.exit_code.must_equal(0)
    # update_vars fills nothing when the origin already carries the var,
    # so the guard passes - and the dispatch still goes to the delegate.
    output.must_include("changed: [h1 -> localhost]")
    output.wont_include("skipping: [h1]")
    output.wont_include("UNREACHABLE")
    output.must_match(/h1\s*: ok=1\s+changed=1\s+unreachable=0\s+failed=0\s+skipped=0/)
    File.exists?("#{PluginSpecHelper.tmp_path("issue-352")}/ran-ssh-origin").must_equal(true)
  ensure
    FileUtils.rm_rf("#{PluginSpecHelper.tmp_path("issue-352")}/ran-ssh-origin") if PluginSpecHelper.tmp_path("issue-352") && Dir.exists?(PluginSpecHelper.tmp_path("issue-352"))
  end

  it "takes the delegate host's own inventory ansible_connection for the guarded when:" do
    status, output = run_playbook(
      "h1 ansible_host=x.invalid\ndelegatehost ansible_connection=local\n",
      <<-YAML
        - hosts: h1
          gather_facts: false
          tasks:
            - name: delegate host own inventory connection var wins the guard
              command: "true"
              delegate_to: delegatehost
              when: ansible_connection == 'local'
        YAML
    )

    status.exit_code.must_equal(0)
    output.must_include("changed: [h1 -> delegatehost]")
    output.wont_include("UNREACHABLE")
    output.must_match(/h1\s*: ok=1\s+changed=1\s+unreachable=0\s+failed=0\s+skipped=0/)
  end
end
