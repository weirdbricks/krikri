require "file_utils"
require "../minitest_helper"

# Runs the compiled binary, since execute_reboot is a private TaskExecutor
# method that builds its result hash around a live SSH wait loop - not
# reachable from a unit spec without stubbing the whole SSH layer.
#
# Ansible's reboot module ALWAYS returns an "elapsed" field (integer
# seconds) in its registered result - confirmed against ansible-core's
# action plugin source: every path after the shutdown command is issued
# sets result['elapsed'], check mode returns {'changed': True, 'elapsed':
# 0, 'rebooted': True}, and the local-connection refusal returns
# 'elapsed': 0 on its failure result. Round900541 derjd.reboot: the
# role's reboot: handler registers its result as rv and a follow-up
# debug: task reads rv.elapsed, which this engine crashed with "object of
# type 'dict' has no attribute 'elapsed'" where Ansible succeeded.
#
# The real wait loop can't run in a spec (a real reboot would kill the
# controller), so these cover the paths that don't need SSH: check mode
# and the local-connection failure - both with register: + a debug:
# rendering rv.elapsed, the exact shape that diverged.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")
# Only needed to reach the check-mode branch without a local connection - no
# SSH is ever attempted in check mode, for either engine.
private NONLOCAL = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-nonlocal-host.ini")

private def run_reboot_playbook(extra_args : Array(String) = [] of String, inventory : String = INVENTORY)
  dir = File.tempname("reboot-elapsed")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "site.yml"), <<-YAML)
    - name: repro
      hosts: all
      gather_facts: false
      tasks:
        - name: reboot the box
          ansible.builtin.reboot:
          register: rv
          ignore_errors: true
        - name: show elapsed
          ansible.builtin.debug:
            msg: "elapsed={{ rv.elapsed }}"
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory] + extra_args + [File.join(dir, "site.yml")],
    output: output, error: output, chdir: dir)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "ansible.builtin.reboot's elapsed result field" do
  it "is present in check mode, so a registered rv.elapsed renders" do
    status, output = run_reboot_playbook(["--check"], NONLOCAL)

    status.success?.must_equal(true)
    output.must_include("elapsed=0")
    output.must_include("changed: [batchhost]")
    output.wont_include("has no attribute")
  end

  it "is present on the local-connection failure result too" do
    # Ansible refuses a local-connection reboot with
    # {'elapsed': 0, ..., 'failed': True} - the field is there even
    # though nothing was rebooted, so the follow-up debug: still works
    # under ignore_errors.
    #
    # The localhost inventory fixture is already ansible_connection=local,
    # so a non-check run takes the local-connection refusal branch.
    status, output = run_reboot_playbook

    status.success?.must_equal(true)
    output.must_include("elapsed=0")
    output.wont_include("has no attribute")
  end

  it "uses Ansible's action-level message for local-connection refusal" do
    status, output = run_reboot_playbook

    status.success?.must_equal(true)
    output.must_include("Running ansible.builtin.reboot with local connection would reboot the control node.")
    output.wont_include("Module failed: Running ansible.builtin.reboot")
  end

  it "refuses the local connection in check mode too, instead of reporting changed" do
    # The action plugin's local-connection guard runs BEFORE its check-mode
    # early return, so --check against ansible_connection=local still fails
    # (and, being a failure rather than a change, never fires a notified
    # handler). Issue #1008 / kpg playbook 000023.
    status, output = run_reboot_playbook(["--check"])

    status.success?.must_equal(true)
    output.must_include("Running ansible.builtin.reboot with local connection would reboot the control node.")
    output.wont_include("changed: [localhost]")
    output.must_include("changed=0")
  end
end
