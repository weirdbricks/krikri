require "file_utils"
require "../minitest_helper"

# any_errors_fatal: and max_fail_percentage: - the play-level "stop the
# rollout" controls. Both were parsed to nothing, so a play written to
# halt the moment a host failed carried right on across the rest of the
# fleet. Expectations from an ansible-core 2.19.4 run over three hosts,
# one of which fails.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_play(keywords : String) : {Int32, Array(String)}
  dir = File.tempname("aef")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh1 ansible_connection=local\nh2 ansible_connection=local\nh3 ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{keywords}
      tasks:
        - name: fail on h2 only
          ansible.builtin.command: /bin/false
          when: inventory_hostname == 'h2'
        - name: later
          ansible.builtin.debug: {msg: "LATER-{{ inventory_hostname }}"}
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s.scan(/LATER-h\d/).map(&.[0]).sort!}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

# Issue #1062's shape: a block whose body fails mid-way under
# max_fail_percentage:. Ansible runs the body's later tasks (on the
# healthy hosts), the always: section and the play's later tasks - a
# failure that leaves a rescue:/always: chain running is never booked
# into _tqm._failed_hosts, the population the threshold is measured
# against. Expectations from an ansible-core 2.21.6 run.
private def run_block_play(keywords : String) : {Int32, Array(String)}
  dir = File.tempname("aef")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh1 ansible_connection=local\nh2 ansible_connection=local\nh3 ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{keywords}
      tasks:
        - block:
            - name: fail on h2 only
              ansible.builtin.command: /bin/false
              when: inventory_hostname == 'h2'
            - name: later
              ansible.builtin.debug: {msg: "LATER-{{ inventory_hostname }}"}
          always:
            - name: always
              ansible.builtin.debug: {msg: "ALWAYS-{{ inventory_hostname }}"}
        - name: after
          ansible.builtin.debug: {msg: "AFTER-{{ inventory_hostname }}"}
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s.scan(/(?:LATER|ALWAYS|AFTER)-h\d/).map(&.[0]).sort!}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

# Same block under a rescue:, which recovers the failed host so it runs
# the play's later tasks too (ansible-core 2.21.6: RESCUE-h2, and
# AFTER-h2 joins AFTER-h1/h3).
private def run_block_rescue_play(keywords : String) : {Int32, Array(String)}
  dir = File.tempname("aef")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh1 ansible_connection=local\nh2 ansible_connection=local\nh3 ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{keywords}
      tasks:
        - block:
            - name: fail on h2 only
              ansible.builtin.command: /bin/false
              when: inventory_hostname == 'h2'
            - name: later
              ansible.builtin.debug: {msg: "LATER-{{ inventory_hostname }}"}
          rescue:
            - name: rescue
              ansible.builtin.debug: {msg: "RESCUE-{{ inventory_hostname }}"}
          always:
            - name: always
              ansible.builtin.debug: {msg: "ALWAYS-{{ inventory_hostname }}"}
        - name: after
          ansible.builtin.debug: {msg: "AFTER-{{ inventory_hostname }}"}
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s.scan(/(?:LATER|ALWAYS|AFTER|RESCUE)-h\d/).map(&.[0]).sort!}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "any_errors_fatal:" do
  # One host failing stops the play for ALL of them - no later task runs
  # anywhere, including on the hosts that were fine.
  it "aborts the play for every host when one fails" do
    code, later = run_play("  any_errors_fatal: true")
    code.must_equal(2)
    later.empty?.must_equal(true)
  end

  # Per BATCH: h1's batch completes, h2's fails, h3's never starts.
  it "stops the remaining serial batches too" do
    code, later = run_play("  serial: 1\n  any_errors_fatal: true")
    code.must_equal(2)
    later.must_equal(["LATER-h1"])
  end
end

describe "max_fail_percentage:" do
  # 1 of 3 hosts = 33.3%, and the comparison is STRICTLY greater.
  it "aborts when the failed share exceeds the limit" do
    run_play("  max_fail_percentage: 20")[1].empty?.must_equal(true)
    run_play("  max_fail_percentage: 33")[1].empty?.must_equal(true)
  end

  it "does not abort when the failed share is within the limit" do
    run_play("  max_fail_percentage: 34")[1].must_equal(["LATER-h1", "LATER-h3"])
    run_play("  max_fail_percentage: 100")[1].must_equal(["LATER-h1", "LATER-h3"])
  end

  it "aborts on any failure at 0" do
    run_play("  max_fail_percentage: 0")[1].empty?.must_equal(true)
  end

  # Issue #1062: a failure inside a block that still owes a rescue:/
  # always: chain never counts toward the threshold (Ansible books only
  # chain-complete failures into _tqm._failed_hosts), so not even 0%
  # aborts - the body's later tasks, the always: section and the play's
  # later tasks all still run.
  it "keeps the block chain and later tasks running after a mid-block failure" do
    code, seen = run_block_play("  max_fail_percentage: 0")
    code.must_equal(2)
    seen.must_equal(["AFTER-h1", "AFTER-h3", "ALWAYS-h1", "ALWAYS-h2", "ALWAYS-h3", "LATER-h1", "LATER-h3"])
  end

  # The block's end re-halts the host its chain failed on, but that halt
  # keeps the original failure's classification - and a rescue: that
  # succeeds hands the host back to the play entirely.
  it "lets rescue: recover the failed host and keeps the play going" do
    seen = run_block_rescue_play("  max_fail_percentage: 0")[1]
    seen.must_equal(["AFTER-h1", "AFTER-h2", "AFTER-h3", "ALWAYS-h1", "ALWAYS-h2", "ALWAYS-h3", "LATER-h1", "LATER-h3", "RESCUE-h2"])
  end
end

describe "neither keyword" do
  # Guard: the default is still "carry on with the hosts that are fine".
  it "leaves the play running for the healthy hosts" do
    code, later = run_play("")
    code.must_equal(2)
    later.must_equal(["LATER-h1", "LATER-h3"])
  end
end
