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

private def run_notified_reboot_playbook(extra_args : Array(String) = [] of String, inventory : String = INVENTORY)
  dir = File.tempname("reboot-notify")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "site.yml"), <<-YAML)
    - name: repro
      hosts: all
      gather_facts: false
      tasks:
        - name: reboot the box
          ansible.builtin.reboot:
          ignore_errors: true
          notify: reboot handler
      handlers:
        - name: reboot handler
          ansible.builtin.debug:
            msg: reboot handler ran
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory] + extra_args + [File.join(dir, "site.yml")],
    output: output, error: output, chdir: dir)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "ansible.builtin.reboot's handler notification" do
  it "does not fire the notified handler when the task fails under check mode" do
    # A handler is notified only by a task that CHANGED; the local-connection
    # refusal is a failure (ignore_errors just keeps the run going), so
    # Ansible never runs the handler. Reporting `changed` here instead made
    # krikri run it and diverge the whole play (issue #1008, kpg 000023).
    status, output = run_notified_reboot_playbook(["--check"])

    status.success?.must_equal(true)
    output.must_include("Running ansible.builtin.reboot with local connection would reboot the control node.")
    output.wont_include("RUNNING HANDLER [reboot handler]")
    output.wont_include("reboot handler ran")
    output.must_include("changed=0")
    output.must_include("ignored=1")
  end
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

# The reboot task itself is controller-side and reaches the target only
# through `ssh`, so a stub `ssh` on the child's PATH is a complete host
# for it. That is the only way to prove a host which accepted the reboot
# command but never went down is not reported as rebooted - a real
# reboot would take the test machine with it.
private def run_reboot_against_fake_ssh(reboots : Bool)
  dir = PluginSpecHelper.tmp_path("reboot-fake-ssh")
  Dir.mkdir_p(dir)
  state = File.join(dir, "boot-id")
  File.write(state, "11111111-1111-1111-1111-111111111111\n")
  on_reboot = reboots ? %(echo '22222222-2222-2222-2222-222222222222' > "#{state}") : "true"
  File.write(File.join(dir, "ssh"), "#!/bin/sh\n" \
                                    "case \"$*\" in\n" \
                                    "  *boot_id*) cat \"#{state}\" ;;\n" \
                                    "  *whoami*) echo tester ;;\n" \
                                    "  *systemctl*|*reboot*) #{on_reboot} ;;\n" \
                                    "esac\n" \
                                    "exit 0\n")
  File.chmod(File.join(dir, "ssh"), 0o755)

  inventory = File.join(dir, "inventory.ini")
  File.write(inventory, "[fake]\nfakehost ansible_connection=ssh ansible_host=127.0.0.1 ansible_port=2200 ansible_user=tester\n")

  File.write(File.join(dir, "site.yml"), <<-YAML)
    - name: repro
      hosts: all
      gather_facts: false
      tasks:
        - name: reboot the box
          ansible.builtin.reboot:
            reboot_timeout: 2
            connect_timeout: 1
            pre_reboot_delay: 0
          register: rv
          ignore_errors: true
        - name: show
          ansible.builtin.debug:
            msg: "rebooted={{ rv.rebooted }} msg={{ rv.msg }}"
    YAML

  # The child resolves `ssh` through its own PATH (Crystal looks the
  # executable up with the PARENT's PATH), so the fake must go into the
  # environment the krikri-playbook process itself gets.
  env = ENV.to_h
  env["PATH"] = "#{dir}:#{ENV["PATH"]?}"
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, File.join(dir, "site.yml")],
    output: output, error: output, chdir: dir, env: env)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "ansible.builtin.reboot's reboot verification" do
  it "times out instead of reporting Reboot complete when the boot id never changes" do
    # Issue #1305: a host that took the reboot command but never went down
    # answered the whoami probe right away, so this engine reported
    # `changed: true, rebooted: true, msg: "Reboot complete", elapsed: 5`
    # while ansible-playbook waits for /proc/sys/kernel/random/boot_id to
    # change (65s on the reporting host) and only then succeeds.
    status, output = run_reboot_against_fake_ssh(reboots: false)

    status.success?.must_equal(true)
    output.must_include("Timed out waiting for last boot time check (timeout=2)")
    output.wont_include("Reboot complete")
    output.must_include("ignored=1")
  end

  it "reports Reboot complete once the boot id does change" do
    status, output = run_reboot_against_fake_ssh(reboots: true)

    status.success?.must_equal(true)
    output.must_include("Reboot complete")
    output.must_include("changed=1")
  end
end
