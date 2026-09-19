require "file_utils"
require "../spec_helper"

# Runs the compiled binary, since execute_reboot is a private TaskExecutor
# method that builds its result hash around a live SSH wait loop - not
# reachable from a unit spec without stubbing the whole SSH layer.
#
# Real Ansible's reboot module ALWAYS returns an "elapsed" field (integer
# seconds) in its registered result - confirmed against ansible-core's
# action plugin source: every path after the shutdown command is issued
# sets result['elapsed'], check mode returns {'changed': True, 'elapsed':
# 0, 'rebooted': True}, and the local-connection refusal returns
# 'elapsed': 0 on its failure result. Round900541 derjd.reboot: the
# role's reboot: handler registers its result as rv and a follow-up
# debug: task reads rv.elapsed, which this engine crashed with "object of
# type 'dict' has no attribute 'elapsed'" where real Ansible succeeded.
#
# The real wait loop can't run in a spec (a real reboot would kill the
# controller), so these cover the paths that don't need SSH: check mode
# and the local-connection failure - both with register: + a debug:
# rendering rv.elapsed, the exact shape that diverged.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_reboot_playbook(extra_args : Array(String) = [] of String)
  dir = File.tempname("reboot-elapsed")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "site.yml"), <<-YAML)
    - name: repro
      hosts: localhost
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
  status = Process.run(BINARY, ["-i", INVENTORY] + extra_args + [File.join(dir, "site.yml")],
    output: output, error: output, chdir: dir)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "ansible.builtin.reboot's elapsed result field" do
  it "is present in check mode, so a registered rv.elapsed renders" do
    status, output = run_reboot_playbook(["--check"])

    status.success?.should be_true
    output.should contain("elapsed=0")
    output.should_not contain("has no attribute")
  end

  it "is present on the local-connection failure result too" do
    # Real Ansible refuses a local-connection reboot with
    # {'elapsed': 0, ..., 'failed': True} - the field is there even
    # though nothing was rebooted, so the follow-up debug: still works
    # under ignore_errors.
    #
    # The localhost inventory fixture is already ansible_connection=local,
    # so a non-check run takes the local-connection refusal branch (in
    # check mode the check-mode branch would short-circuit first).
    status, output = run_reboot_playbook

    status.success?.should be_true
    output.should contain("elapsed=0")
    output.should contain("not supported over a local connection")
    output.should_not contain("has no attribute")
  end
end
