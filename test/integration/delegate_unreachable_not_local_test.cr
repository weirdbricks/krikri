require "../minitest_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/host"

# Issue #102: a `delegate_to:` name that is neither in the inventory nor a
# localhost spelling is a plain SSH target in ansible - its connection
# plugin defaults to ssh and it NEVER inherits the origin host's
# ansible_connection=local. krikri's not-in-inventory delegate fallback
# Host used to carry no ansible_connection at all, so
# PluginManager.local_connection?'s vars fallback re-inherited the local
# origin's "local": `delegate_to: mynode.mycluster.invalid` from a local
# controller reported `changed: [testhost -> mynode.mycluster.invalid]`
# where ansible-core 2.19 fails the task UNREACHABLE with the ssh resolve
# failure in the msg (recap unreachable=1, rc 4). The same fallback also
# leaked the ORIGIN's ansible_host into ConnectionSettings.resolve, so the
# ssh attempt (and an inventory-host delegate's ssh attempt) named the
# origin instead of the delegate.
#
# Ansible books a delegated task's unreachable on the ORIGIN host alone
# (the delegate never enters the recap), and stamps every line of a
# delegated task with the `host -> delegate` label via
# CallbackBase.host_label.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_playbook(inventory : String, yaml : String) : {Process::Status, String}
  dir = PluginSpecHelper.tmp_path("issue-102")
  FileUtils.mkdir_p(dir)
  inv = File.join(dir, "inv.ini")
  File.write(inv, inventory)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inv, playbook], output: output, error: output)
  {status, output.to_s}
end

describe "delegated task to a host not in the inventory (issue #102)" do
  it "fails UNREACHABLE over ssh to the delegate name, not changed locally" do
    status, output = run_playbook(
      "testhost ansible_connection=local\n",
      <<-YAML
        - hosts: testhost
          gather_facts: false
          tasks:
            - name: delegated
              command: "true"
              delegate_to: mynode.mycluster.invalid
        YAML
    )

    status.exit_code.must_equal(4)
    # The fatal line carries the `-> delegate` label and the ssh error
    # names the DELEGATE (the origin's ansible_host must not leak into
    # the delegated connection).
    output.must_match(/fatal: \[testhost -> mynode\.mycluster\.invalid\]: UNREACHABLE! => \{"changed": false, "msg": "Task failed: Failed to connect to the host via ssh: ssh: Could not resolve hostname mynode\.mycluster\.invalid/)
    output.wont_match(/changed: \[testhost/)
    output.must_match(/testhost\s*: ok=0\s+changed=0\s+unreachable=1\s+failed=0/)
  end

  it "still runs delegated localhost tasks locally" do
    status, output = run_playbook(
      "testhost ansible_connection=local\n",
      <<-YAML
        - hosts: testhost
          gather_facts: false
          tasks:
            - name: delegated
              command: "true"
              delegate_to: localhost
        YAML
    )

    status.exit_code.must_equal(0)
    output.must_match(/changed: \[testhost -> localhost\]/)
    output.must_match(/testhost\s*: ok=1\s+changed=1\s+unreachable=0/)
  end

  it "ssh's an inventory-host delegate to the DELEGATE's name, not the origin's" do
    # otherhost.invalid is deliberately unresolvable: the point is which
    # hostname the ssh attempt NAMES - before the fix the delegated
    # dispatch resolved the connection from the origin's context and
    # tried to ssh to testhost.
    status, output = run_playbook(
      "testhost ansible_connection=local\notherhost.invalid ansible_connection=ssh\n",
      <<-YAML
        - hosts: testhost
          gather_facts: false
          tasks:
            - name: delegated
              command: "true"
              delegate_to: otherhost.invalid
        YAML
    )

    status.exit_code.must_equal(4)
    output.must_match(/Failed to connect to the host via ssh: ssh: Could not resolve hostname otherhost\.invalid/)
    output.wont_match(/Could not resolve hostname testhost/)
    output.must_match(/fatal: \[testhost -> otherhost\.invalid\]: UNREACHABLE!/)
    output.must_match(/testhost\s*: ok=0\s+changed=0\s+unreachable=1\s+failed=0/)
  end
end

describe "Krikri::PluginManager (delegate_unreachable_not_local_test.cr)" do
  it "a fallback delegate host with its own ssh connection is never local, even with local origin vars" do
    # The shape resolve_delegate_host's not-in-inventory fallback now
    # produces: the delegate carries its own ansible_connection=ssh, so
    # the origin's local connection must not win the classification.
    origin_vars = {"ansible_connection" => JSON::Any.new("local")}
    fallback_delegate = Krikri::Host.new("mynode.mycluster.invalid", ENV["USER"]? || "root", 22)
    fallback_delegate.vars["ansible_connection"] = JSON::Any.new("ssh")
    Krikri::PluginManager.local_connection?(fallback_delegate, origin_vars).must_equal(false)
  end
end
