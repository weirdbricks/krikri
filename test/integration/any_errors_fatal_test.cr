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

# Issue #1481's shape: one host of the fleet is simply unreachable (a
# refused ssh connection, so no real network dependency) while the others
# are local. Ansible books it in _tqm._unreachable_hosts, never in
# _tqm._failed_hosts - the population max_fail_percentage: is measured
# against - so even 0% must not abort the play for the healthy hosts.
private def run_unreachable_play(keywords : String) : {Int32, Array(String)}
  dir = File.tempname("aef")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), <<-INI)
    [g]
    h1 ansible_connection=local
    h2 ansible_connection=local
    dead ansible_host=127.0.0.1 ansible_port=1
    INI
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{keywords}
      tasks:
        - name: first
          ansible.builtin.command: /bin/true
        - name: later
          ansible.builtin.debug: {msg: "LATER-{{ inventory_hostname }}"}
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "-f", "1", "pb.yml"],
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

# Issue #1534: a play that max_fail_percentage: ends gets the default
# callback's "NO MORE HOSTS LEFT" banner - TWICE, because Ansible's
# linear strategy sends it from the threshold check and then again from
# the "all hosts have failed" check right below, which the first check's
# own mark-every-host-failed made true. Returns the exit code and how
# many banners printed (live-verified vs ansible-core 2.21.6).
private def run_banner_play(keywords : String) : {Int32, Int32}
  dir = File.tempname("aef")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "[g]\nh1 ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{keywords}
      tasks:
        - name: fails
          ansible.builtin.command: /bin/false
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s.scan(/^NO MORE HOSTS LEFT \*+$/m).size}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

# Issue #1534's own shape: the failure that crosses the threshold is the
# play's HANDLER, run by `meta: flush_handlers` as the play's last task -
# no later task iteration is left for the between-tasks check, and the
# banner pair still belongs right after the handler's fatal, before the
# recap (live-verified vs ansible-core 2.21.6). Returns the exit code and
# the whole output.
private def run_handler_banner_play(keywords : String) : {Int32, String}
  dir = File.tempname("aef")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "[g]\nh1 ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{keywords}
      tasks:
        - name: notifier
          ansible.builtin.command:
            cmd: /bin/true
          changed_when: true
          notify: Kpg handler
        - name: flush
          ansible.builtin.meta: flush_handlers
      handlers:
        - name: Kpg handler
          ansible.builtin.command:
            cmd: /bin/false
          changed_when: false
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s}
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

  # Ansible's any_errors_fatal: branch marks the fleet failed but never
  # enters the max_fail_percentage: block that sends the banner, so this
  # abort is silent while a threshold abort is not (live-verified).
  it "ends the play without the no-more-hosts banner" do
    code, banners = run_banner_play("  any_errors_fatal: true")
    code.must_equal(2)
    banners.must_equal(0)
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

  # Issue #1534: the banner pair, in its own paragraph before the recap.
  it "prints the no-more-hosts banner twice when the threshold ends the play" do
    code, banners = run_banner_play("  max_fail_percentage: 0")
    code.must_equal(2)
    banners.must_equal(2)
  end

  it "prints no banner when the failure stays within the limit" do
    code, banners = run_banner_play("  max_fail_percentage: 100")
    code.must_equal(2)
    banners.must_equal(0)
  end

  # A failure with no max_fail_percentage: at all never reaches Ansible's
  # threshold block either - the play just runs out of hosts.
  it "prints no banner for a failure without the threshold" do
    code, banners = run_banner_play("")
    code.must_equal(2)
    banners.must_equal(0)
  end

  # Issue #1534's shape: the aborting failure is a HANDLER, so the
  # between-tasks check has no later task to run on.
  it "prints the banner twice when a handler failure crosses the threshold" do
    code, output = run_handler_banner_play("  max_fail_percentage: 0")
    code.must_equal(2)
    output.must_match(/NO MORE HOSTS LEFT \*+\n\nNO MORE HOSTS LEFT \*+\n\nPLAY RECAP/)
  end

  it "does not count an unreachable host toward the threshold" do
    code, later = run_unreachable_play("  max_fail_percentage: 0")
    code.must_equal(4)
    later.must_equal(["LATER-h1", "LATER-h2"])
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
