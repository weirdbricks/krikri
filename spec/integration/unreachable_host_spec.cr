require "file_utils"
require "../spec_helper"

# An unreachable host must be REPORTED and skipped, not fatal. This used
# to kill the whole process with a raw Crystal stack trace ("Unhandled
# exception: Failed to upload ... Could not resolve hostname"), print no
# recap at all, discard every reachable host's results, and exit 1.
#
# Real ansible-playbook (2.19.4) reports the host UNREACHABLE!, keeps
# going for the others, recaps it as unreachable=1, and exits 4 - which
# it returns whenever any host was unreachable, ahead of a failed host's
# 2. Verified for all-unreachable, mixed-with-ok and mixed-with-failed.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def run_inventory(inventory : String)
  dir = File.tempname("unreachable")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), inventory)
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
      tasks:
        - name: t
          ansible.builtin.command: /bin/true
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "-T", "5", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

private UNREACHABLE = "bogus ansible_host=no-such-host.invalid ansible_user=nobody\n"
private REACHABLE   = "good ansible_connection=local\n"

describe "unreachable hosts" do
  it "reports an unreachable host and exits 4 instead of crashing" do
    status, output = run_inventory(UNREACHABLE)

    status.exit_code.should eq(4)
    output.should_not contain("Unhandled exception")
    output.should contain("UNREACHABLE!")
    output.should match(/bogus\s+: ok=0\s+changed=0\s+unreachable=1/)
  end

  # The regression that mattered most: one dead host used to take the
  # whole run down with it.
  it "still runs, and still reports, every reachable host" do
    status, output = run_inventory(REACHABLE + UNREACHABLE)

    status.exit_code.should eq(4)
    output.should_not contain("Unhandled exception")
    output.should match(/good\s+: ok=1/)
    output.should match(/bogus\s+: ok=0\s+changed=0\s+unreachable=1/)
  end

  it "recaps hosts in sorted order, as real Ansible does" do
    _, output = run_inventory(REACHABLE + UNREACHABLE)
    bogus_at = output.index("bogus  ")
    good_at = output.index("good  ")
    (bogus_at && good_at && bogus_at < good_at).should be_true
  end
end

describe "ignore_unreachable:" do
  # Real Ansible attempts the task, reports UNREACHABLE!, counts it as
  # ok AND ignored, and lets the host CARRY ON - the next task without
  # the flag then fails unreachable normally. Verified against
  # ansible-core 2.19.4: bogus recaps
  # `ok=1 unreachable=1 ignored=1`, good `ok=2 changed=2`.
  it "tolerates an unreachable host for that task and continues" do
    dir = File.tempname("ignore-unreachable")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"), REACHABLE + UNREACHABLE)
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: unreachable but tolerated
            ansible.builtin.command: /bin/true
            ignore_unreachable: true
          - name: later task
            ansible.builtin.command: echo LATER
      YAML

    begin
      stdout_io = IO::Memory.new
      status = Process.run(BINARY, ["-i", "inv.ini", "-T", "5", "pb.yml"],
        output: stdout_io, error: stdout_io, chdir: dir)
      output = stdout_io.to_s

      status.exit_code.should eq(4)
      output.should match(/bogus\s+: ok=1\s+changed=0\s+unreachable=1\s+failed=0\s+skipped=0\s+rescued=0\s+ignored=1/)
      output.should match(/good\s+: ok=2\s+changed=2/)
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
