require "../spec_helper"
require "file_utils"

# Real bug found benchmarking konstruktoid.docker_rootless's warm run
# (round 400036): its "Enable lingering for the Docker user" task is
# `command: loginctl enable-linger ...` with `creates:`, `register:`,
# and `changed_when: [user_linger.rc == 0, "'skipped' not in
# user_linger.stdout"]`. On the warm run the creates: file already
# exists, so the module never runs - and real ansible-core 2.19.4's
# skip result still carries the FULL command-module shape, `rc: 0`
# included (live-verified: `{"changed": false, "cmd": [...], "delta":
# null, ..., "rc": 0, "stdout": "skipped, since ... exists",
# "stdout_lines": [...]}`), so the changed_when: evaluates cleanly to
# changed: false. This engine's plugin returned a bare msg/stdout pair
# with NO rc at all, so the registered result had no `rc` key and the
# changed_when: hard-failed the task with "object of type 'dict' has no
# attribute 'rc'" - the whole warm run diverged only on krikri's side.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a creates:-skipped command result carries rc: 0" do
  it "lets a later changed_when: read .rc/.stdout on the registered skip" do
    marker = File.tempname("creates-skip-marker")
    File.write(marker, "x")

    playbook = File.tempname("creates-skip-rc", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: skip via creates
            command:
              cmd: /bin/true
              creates: #{marker}
            register: user_linger
            changed_when:
              - user_linger.rc == 0
              - "'skipped' not in user_linger.stdout"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("Did not run command since")
    output.to_s.should_not match(/failed=1\b/)
    output.to_s.should_not contain("has no attribute 'rc'")
  ensure
    File.delete(marker) if marker && File.exists?(marker)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
