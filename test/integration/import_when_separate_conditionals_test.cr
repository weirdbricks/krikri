require "../minitest_helper"

# The import_tasks:/include_role: when: and the inlined child task's own
# when: are TWO SEPARATE strict conditionals in real - each one
# type-checked for a boolean result on its own. Joining them into one
# "(import) and (child)" string lost that per-clause boundary: a truthy
# string var in the import's when: (`when: user` with user: "ec2-user",
# clouddrove.ansible_role_common - round 5210000) short-circuited the
# and-expression into a boolean and the child task RAN where real failed
# the whole import at its first inlined task.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("import-when-split", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "import_tasks: when: + child when: are separate strict conditionals" do
  it "fails the import at its first inlined task on a non-boolean import when" do
    inner = File.tempname("import-when-inner", ".yml")
    File.write(inner, <<-YAML)
      ---
      - name: child with own when
        ansible.builtin.debug:
          msg: "CHILD-RAN"
        when: true
      - name: child without own when
        ansible.builtin.debug:
          msg: "CHILD2-RAN"
      YAML

    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          username: "ec2-user"
        tasks:
          - import_tasks: #{inner}
            vars:
              user: "{{ username }}"
            when: user
      YAML

    # The error banner quotes the inner file's source lines (which contain
    # the msg markers), so assert on task outcomes, not marker text.
    output.wont_include("ok: [localhost]")
    output.wont_include("changed: [localhost]")
    output.must_include("Conditionals must have a boolean result")
    output.must_match(/failed=1\b/)
  ensure
    File.delete(inner) if inner && File.exists?(inner)
  end

  it "still runs both clauses when they are genuinely boolean" do
    inner = File.tempname("import-when-inner-bool", ".yml")
    File.write(inner, <<-YAML)
      ---
      - name: child with own when
        ansible.builtin.debug:
          msg: "CHILD-RAN"
        when: true
      YAML

    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          flag: true
        tasks:
          - import_tasks: #{inner}
            vars:
              user: "{{ flag }}"
            when: user | bool
      YAML

    status.success?.must_equal(true)
    output.must_include("ok: [localhost]")
  ensure
    File.delete(inner) if inner && File.exists?(inner)
  end
end
