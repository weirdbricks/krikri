require "../minitest_helper"

# Issue #457 (live-verified vs ansible-core 2.19.11): a looped task's
# `when: item.<key>` strict-conditional failure is lineage-labeled with
# where the TESTED VALUE was defined - the failing item's own `<key>:`
# value token inside the task's literal inline loop: list (column of the
# value start) - not the task's when: token, and each failing loop item
# prints its own [ERROR] chain block immediately before that item's
# failed: line (the per-item origins make the block texts distinct, so
# Display's dedup no longer collapses the repeats).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("loop-item-when-origin", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s, playbook}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "loop item when origin" do
  it "labels each failing item with its own loop-list value token" do
    status, output, playbook = run_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: Loop item when string
          when: item.when
          ansible.builtin.debug:
            msg: hi
          loop:
            - path: a
              when: "'abc'"
            - path: b
              when: "'def'"
    YAML

    status.exit_code.must_equal(2)
    output.must_include("was derived from value of type 'str' at '#{playbook}:11:17'. Conditionals must have a boolean result.")
    output.must_include("was derived from value of type 'str' at '#{playbook}:13:17'. Conditionals must have a boolean result.")
    # One chain block per failing item, not one per task.
    output.scan("[ERROR]: Task failed:").size.must_equal(2)
    # Each block's second Origin (the caused-by stanza) still points at
    # the task's own when: token - real keeps that too.
    output.scan("Origin: #{playbook}:6:13").size.must_equal(2)
    # Interleaving: item 1's block precedes item 1's failed line, which
    # precedes item 2's block and failed line.
    b1 = output.index!("#{playbook}:11:17")
    f1 = output.index!("(item={'path': 'a'")
    b2 = output.index!("#{playbook}:13:17")
    f2 = output.index!("(item={'path': 'b'")
    (b1 < f1 && f1 < b2 && b2 < f2).must_equal(true)
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"One or more items failed\"}")
  end

  it "labels the bracket spelling item['when'] the same way" do
    status, output, playbook = run_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: Loop item when bracket
          when: item['when']
          ansible.builtin.debug:
            msg: hi
          loop:
            - path: a
              when: "'abc'"
            - path: b
              when: "'def'"
    YAML

    status.exit_code.must_equal(2)
    output.must_include("was derived from value of type 'str' at '#{playbook}:11:17'. Conditionals must have a boolean result.")
    output.must_include("was derived from value of type 'str' at '#{playbook}:13:17'. Conditionals must have a boolean result.")
    output.scan("[ERROR]: Task failed:").size.must_equal(2)
  end
end
