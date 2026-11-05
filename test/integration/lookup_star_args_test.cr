require "../minitest_helper"

# Issue #842: the same `*sequence` call-argument unpacking Jinja2 applies
# at template level must also hold where a task parameter is finalized
# from the hand-rolled evaluator, e.g. a `command:` free-form string with
# an embedded `{{ lookup(..., *t) }}` (live-verified against
# ansible-core 2.19.11: the lookup receives the sequence's elements as
# separate terms, it is never read as multiplication).
private PROJECT_ROOT       = File.expand_path("../..", __DIR__)
private BINARY             = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY          = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")
private ISSUE_842_PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    vars:
      t: [a, b]
    tasks:
      - ansible.builtin.command: "echo {{ range(*t | map('int') | list) | list }}"
        register: ranged
      - ansible.builtin.command: "echo {{ lookup('ansible.builtin.items', *t) }}"
        register: looked_up
      - ansible.builtin.debug:
          msg: "{{ ranged.stdout }}|{{ looked_up.stdout }}"
  YAML

describe "star-args call inside module args (issue #842)" do
  it "unpacks *sequence into lookup terms instead of multiplying" do
    playbook = File.tempname("issue842", ".yml")
    File.write(playbook, ISSUE_842_PLAYBOOK)
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(true, text)
    text.wont_include("unsupported operand type(s)")
    text.wont_include("Finalization of task args")
    text.must_include(%("msg": "[]|a,b"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
