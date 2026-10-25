require "../minitest_helper"
require "file_utils"

# Task-arg finalization failures on tasks WITHOUT a name: (the task origin is
# the module key line itself, so Ansible prints two levels), free-form command
# args reported as _raw_params, action-only modules without a `changed` key,
# and Python-typed attribute errors. Live-compared byte for byte with
# ansible-playbook 2.19.11 via scripts/output_parity.sh on the same playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (nameless tasks)" do
  it "prints the two-level block, _raw_params, typed attribute errors and omits changed for debug" do
    playbook = File.tempname("finalization-block", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          d: {a: 1}
        tasks:
          - ansible.builtin.debug:
              msg: "{{ d.a.b.c }}"
            ignore_errors: true
          - ansible.builtin.command: "echo {{ missing_var }}"
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': object of type 'int' has no attribute 'b'")
    text.must_include("\nTask failed: Finalization of task args for 'ansible.builtin.debug' failed.\nOrigin: #{playbook}:6:7")
    text.must_include("<<< caused by >>>")
    text.must_include("Error while resolving value for 'msg': object of type 'int' has no attribute 'b'\nOrigin: #{playbook}:7:14")
    # action-only module: no changed key; Ansible module: changed false
    text.must_include(%(fatal: [localhost]: FAILED! => {"msg": "Task failed: Finalization of task args for 'ansible.builtin.debug' failed))
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Finalization of task args for 'ansible.builtin.command' failed: Error while resolving value for '_raw_params': 'missing_var' is undefined"}))
    # only ONE block per failure (the result display no longer adds a second)
    text.scan("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug'").size.must_equal(1)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

describe "task-arg finalization error block (flow-style k=v string args, issue #237)" do
  it "points a non-first k=v key's undefined failure at the string args start" do
    # ansible's string args layer carries the Origin, so the failing
    # `value=` key points at the whole args string's first character
    # (col 16 = just past `debconf: `), not at the key itself (col 38).
    playbook = File.tempname("finalization-block-kv", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: X
            debconf: name='a' question='b' value='{{ undef_var | quote }}' vtype='password'
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debconf' failed: Error while resolving value for 'value': 'undef_var' is undefined")
    text.must_include("\nTask failed.\nOrigin: #{playbook}:5:7")
    text.must_include("\nFinalization of task args for 'ansible.builtin.debconf' failed.\nOrigin: #{playbook}:6:7")
    text.must_include("Error while resolving value for 'value': 'undef_var' is undefined\nOrigin: #{playbook}:6:16\n")
    text.must_include("6       debconf: name='a' question='b' value='{{ undef_var | quote }}' vtype='password'\n                 ^ column 16\n")
    output.to_s.must_match(/failed=1/)
    output.to_s.wont_include("SHOULD-RUN-AFTER")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end

describe "task-arg finalization error block (free-form k=v folded past the module line, issue #336)" do
  it "points a k=v key's undefined failure at the string start on the module line" do
    # the module-line k=v fragment and the deeper lines under it are ONE
    # plain scalar, so ansible's string args still anchor on the module
    # line: with sha256sum undefined, real 2.19 names the innermost Origin
    # at col 16 (just past `get_url: `), the same position the same-line
    # k=v case already reports, NOT the failing key's own line/column.
    playbook = File.tempname("finalization-block-kv-fold", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: X
            get_url: url=http://h/x.tgz
                     dest=/tmp/x.tgz
                     sha256sum={{ undef_var }}
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.get_url' failed: Error while resolving value for 'sha256sum': 'undef_var' is undefined")
    text.must_include("\nTask failed.\nOrigin: #{playbook}:5:7")
    text.must_include("\nFinalization of task args for 'ansible.builtin.get_url' failed.\nOrigin: #{playbook}:6:7")
    text.must_include("Error while resolving value for 'sha256sum': 'undef_var' is undefined\nOrigin: #{playbook}:6:16\n")
    text.must_include("6       get_url: url=http://h/x.tgz\n                 ^ column 16\n")
    output.to_s.must_match(/failed=1/)
    output.to_s.wont_include("SHOULD-RUN-AFTER")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
