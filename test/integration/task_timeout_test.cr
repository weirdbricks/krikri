require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/task_batcher"

# The task-level `timeout:` keyword, end to end through bin/krikri-playbook.
# Every expected string below was live-captured from ansible-core 2.19.11
# running the same playbook locally (connection: local, `shell: sleep 30`
# with `timeout: 2` and variants: loop, ignore_errors, rescue, block-/
# play-/roles:-entry inheritance, timeout: 0, an out-of-range value, a
# templated value, include_tasks, register).
#
# Real leaves the timed-out module's own child processes running as
# orphans (its SIGALRM only unwinds the controller); krikri's deadline
# kill takes the plugin's whole process group down, so the leak probe
# below pins the stricter behavior.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private PLAY_HEADER = [
  "- hosts: localhost",
  "  gather_facts: false",
  "  connection: local",
  "  tasks:",
]

private def run_play(tasks : Array(String)) : {Bool, String}
  playbook = PluginSpecHelper.tmp_path("task-timeout-#{Random::Secure.hex(4)}.yml")
  File.write(playbook, (PLAY_HEADER + tasks).join("\n") + "\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
  {status.success?, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Whether any `sleep 900 # <marker>` process this test spawned is still
# alive - the leak probe for the deadline kill.
private def leaked_sleep?(marker : String) : Bool
  output = IO::Memory.new
  Process.run("pgrep", ["-f", "sleep 900 # #{marker}"], output: output)
  !output.to_s.strip.empty?
end

private FATAL_LINE = "fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Timed out after 2 second(s).\", \"timedout\": {\"frame\": \"Configure `DISPLAY_TRACEBACK` to see a traceback on timeout errors.\", \"period\": 2}}"

describe "task timeout keyword" do
  it "fails a task that outlives its timeout with Ansible's exact output" do
    marker = Random::Secure.hex(6)
    success, output = run_play([
      "    - name: slow",
      "      ansible.builtin.shell: sleep 900 # #{marker}",
      "      timeout: 2",
    ])

    success.must_equal(false)
    output.includes?("[ERROR]: Task failed: Timed out after 2 second(s).").must_equal(true, output)
    output.includes?(FATAL_LINE).must_equal(true, output)
    output.includes?("localhost                  : ok=0    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0").must_equal(true, output)
    leaked_sleep?(marker).must_equal(false, "timed-out plugin process leaked")
  end

  it "applies the timeout per loop item and keeps the loop shape" do
    success, output = run_play([
      "    - name: loop slow",
      "      ansible.builtin.shell: sleep 900",
      "      timeout: 2",
      "      loop: [a, b]",
    ])

    success.must_equal(false)
    output.includes?("failed: [localhost] (item=a) => {\"ansible_loop_var\": \"item\", \"changed\": false, \"item\": \"a\", \"msg\": \"Task failed: Timed out after 2 second(s).\", \"timedout\": {\"frame\": \"Configure `DISPLAY_TRACEBACK` to see a traceback on timeout errors.\", \"period\": 2}}").must_equal(true, output)
    output.includes?("failed: [localhost] (item=b) => {\"ansible_loop_var\": \"item\", \"changed\": false, \"item\": \"b\", \"msg\": \"Task failed: Timed out after 2 second(s).\", \"timedout\": {\"frame\": \"Configure `DISPLAY_TRACEBACK` to see a traceback on timeout errors.\", \"period\": 2}}").must_equal(true, output)
  end

  it "honors ignore_errors and plays on" do
    success, output = run_play([
      "    - name: slow ignored",
      "      ansible.builtin.shell: sleep 900",
      "      timeout: 2",
      "      ignore_errors: true",
      "    - ansible.builtin.debug:",
      "        msg: after",
    ])

    success.must_equal(true)
    output.includes?(FATAL_LINE).must_equal(true, output)
    output.includes?("...ignoring").must_equal(true, output)
    output.includes?("\"msg\": \"after\"").must_equal(true, output)
    output.includes?("ok=2    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=1").must_equal(true, output)
  end

  it "feeds rescue: like any other task failure" do
    success, output = run_play([
      "    - name: rescue test",
      "      block:",
      "        - ansible.builtin.shell: sleep 900",
      "          timeout: 2",
      "      rescue:",
      "        - ansible.builtin.debug:",
      "            msg: rescued",
    ])

    success.must_equal(true)
    output.includes?(FATAL_LINE).must_equal(true, output)
    output.includes?("\"msg\": \"rescued\"").must_equal(true, output)
    output.includes?("ok=1    changed=0    unreachable=0    failed=0    skipped=0    rescued=1    ignored=0").must_equal(true, output)
  end

  it "inherits a block-level timeout" do
    success, output = run_play([
      "    - name: block timeout",
      "      block:",
      "        - ansible.builtin.shell: sleep 900",
      "      timeout: 2",
    ])

    success.must_equal(false)
    output.includes?(FATAL_LINE).must_equal(true, output)
  end

  it "inherits a play-level timeout" do
    playbook = PluginSpecHelper.tmp_path("task-timeout-play-#{Random::Secure.hex(4)}.yml")
    File.write(playbook, [
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  timeout: 2",
      "  tasks:",
      "    - name: slow",
      "      ansible.builtin.shell: sleep 900",
    ].join("\n") + "\n")
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
    status.success?.must_equal(false)
    output.to_s.includes?(FATAL_LINE).must_equal(true, output.to_s)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "inherits a roles:-entry timeout" do
    role_dir = PluginSpecHelper.tmp_path("timeout-role")
    FileUtils.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "tasks", "main.yml"),
      "- name: role sleep\n  ansible.builtin.shell: sleep 900\n")
    playbook = PluginSpecHelper.tmp_path("task-timeout-role-#{Random::Secure.hex(4)}.yml")
    File.write(playbook, [
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  roles:",
      "    - role: timeout-role",
      "      timeout: 2",
    ].join("\n") + "\n")
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", playbook],
      output: output, error: output, input: IO::Memory.new, env: {"ANSIBLE_ROLES_PATH" => File.dirname(playbook)})
    status.success?.must_equal(false)
    output.to_s.includes?(FATAL_LINE).must_equal(true, output.to_s)
  ensure
    FileUtils.rm_rf(role_dir) if role_dir
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "treats timeout 0 as no limit" do
    success, output = run_play([
      "    - name: slow but unbounded",
      "      ansible.builtin.shell: sleep 2",
      "      timeout: 0",
    ])

    success.must_equal(true)
    output.includes?("changed: [localhost]").must_equal(true, output)
  end

  it "fails an out-of-range timeout with Ansible's exact wording" do
    success, output = run_play([
      "    - name: neg",
      "      ansible.builtin.shell: echo hi",
      "      timeout: -5",
      "      ignore_errors: true",
    ])

    success.must_equal(true)
    output.includes?("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Timeout -5 is invalid, it must be between 0 and 100000000.\"}").must_equal(true, output)
    output.includes?("...ignoring").must_equal(true, output)
  end

  it "resolves a templated timeout to an integer" do
    success, output = run_play([
      "    - name: templated ok",
      "      ansible.builtin.shell: echo hi",
      "      timeout: \"{{ three }}\"",
      "      vars:",
      "        three: 3",
    ])

    success.must_equal(true)
    output.includes?("changed: [localhost]").must_equal(true, output)
  end

  it "fails a templated non-integer timeout with Ansible's exact brief" do
    success, output = run_play([
      "    - name: templated bad",
      "      ansible.builtin.shell: echo hi",
      "      timeout: \"{{ bad }}\"",
      "      ignore_errors: true",
      "      vars:",
      "        bad: abc",
    ])

    success.must_equal(true)
    output.includes?("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Error processing keyword 'timeout': The value 'abc' could not be converted to 'int'.\"}").must_equal(true, output)
    output.includes?("...ignoring").must_equal(true, output)
  end

  it "bounds only the include statement, not the included tasks" do
    included = PluginSpecHelper.tmp_path("task-timeout-inc-#{Random::Secure.hex(4)}.yml")
    File.write(included, "- ansible.builtin.shell: echo inner\n")
    playbook = PluginSpecHelper.tmp_path("task-timeout-include-#{Random::Secure.hex(4)}.yml")
    File.write(playbook, [
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  tasks:",
      "    - name: include wrapper",
      "      ansible.builtin.include_tasks: #{included}",
      "      timeout: 2",
    ].join("\n") + "\n")
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
    status.success?.must_equal(true)
    output.to_s.includes?("changed: [localhost]").must_equal(true, output.to_s)
  ensure
    File.delete(included) if included && File.exists?(included)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "registers the timed-out result with real's key set" do
    success, output = run_play([
      "    - name: slow",
      "      ansible.builtin.shell: sleep 900",
      "      timeout: 2",
      "      register: r",
      "      ignore_errors: true",
      "    - ansible.builtin.debug:",
      "        msg: \"{{ r.timedout.period }}\"",
    ])

    success.must_equal(true)
    output.includes?(FATAL_LINE).must_equal(true, output)
    output.includes?("\"msg\": 2").must_equal(true, output)
  end

  it "never shares a batch group with its neighbors" do
    # A batched task's result only comes back with its whole group's SSH
    # round trip, so a per-task deadline is unenforceable inside one -
    # the planner must break the run around it like until:/async: tasks.
    playbook = Krikri::PlaybookParser.parse_string([
      "- hosts: localhost",
      "  gather_facts: false",
      "  tasks:",
      "    - name: a",
      "      ansible.builtin.command: echo hi",
      "    - name: slow",
      "      ansible.builtin.shell: sleep 900",
      "      timeout: 2",
      "    - name: c",
      "      ansible.builtin.command: echo hi",
    ].join("\n"))
    groups = Krikri::TaskBatcher.plan(playbook.plays[0].tasks).map { |group| group.map(&.name) }
    shared = groups.any? { |group| group.includes?("slow") && group.size > 1 }
    shared.must_equal(false, groups.to_s)
  end
end
