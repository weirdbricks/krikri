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

describe "task-arg finalization error block (two same-named tasks, issue #338)" do
  it "points a repeated-name failure at the SECOND task's own lines, not the first copy's" do
    # ansible Origins each task error at that task's OWN YAML mapping, so a
    # tasks file may repeat a name (ecaepp.ansible_role_nginx repeats the
    # Python-OpenSSL install task): the failing second task must not inherit
    # the first (when:-skipped) copy's position - the pre-fix first-match
    # scan pinned every Origin to line 5/6/7 of the first copy.
    playbook = File.tempname("finalization-block-dupname", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: Same name
            ansible.builtin.debug:
              msg: "{{ python2_pkgs }}"
            when: false

          - name: Same name
            ansible.builtin.debug:
              msg: "{{ python3-pkgs }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': 'python3' is undefined")
    text.must_include("\nTask failed.\nOrigin: #{playbook}:10:7")
    text.must_include("\nFinalization of task args for 'ansible.builtin.debug' failed.\nOrigin: #{playbook}:11:7")
    text.must_include("Error while resolving value for 'msg': 'python3' is undefined\nOrigin: #{playbook}:12:14\n")
    text.must_include("12         msg: \"{{ python3-pkgs }}\"\n                ^ column 14\n")
    text.must_match(/skipping: \[localhost\]/)
    text.wont_include("python2_pkgs")
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

describe "task-arg finalization error block (quoted templated set_fact key + lookup('vars'), issue #505)" do
  it "chains the include_vars Origin through the quoted templated key and points stanza 3 at its value token" do
    # galaxyproject.galaxy's layout task keys each fact with the
    # unrendered `"{{ item }}"` and looks the default up as
    # `lookup('vars', '__' ~ item)`: real 2.19 still prints the full
    # chain - the quoted key's own value token for stanza 3 (line 9 col
    # 19 here, the opening quote), and a fourth stanza whose Origin is
    # the include_vars definition the runtime lookup actually reached.
    dir = File.tempname("finalization-block-i505")
    Dir.mkdir(dir)
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - include_vars: defaults.yml
          - include_tasks: layout.yml
      YAML
    defaults = File.join(dir, "defaults.yml")
    File.write(defaults, <<-YAML)
      ---
      # layout defaults
      # padding
      __x: "{{ undef_y }}/z"
      YAML
    layout = File.join(dir, "layout.yml")
    File.write(layout, <<-YAML)
      ---
      # Configure any unset variables using layout defaults
      # padded so the templated key sits on line 9
      # padding
      # padding
      # padding
      - name: Set any unset variables from layout defaults
        set_fact:
          "{{ item }}": "{{ lookup('vars', '__' ~ item) }}"
        with_items:
          - x
          - y
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    # Item x: `__x` IS defined, so the failure is its own value's
    # undefined reference - four stanzas, the fourth pointing at the
    # include_vars layer the text scan alone could never reach.
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for '{{ item }}': 'undef_y' is undefined")
    text.must_include("Error while resolving value for '{{ item }}'.\nOrigin: #{layout}:9:19")
    text.must_include("9     \"{{ item }}\": \"{{ lookup('vars', '__' ~ item) }}\"\n                    ^ column 19\n")
    text.must_include("'undef_y' is undefined\nOrigin: #{defaults}:4:6\n")
    # Item y: `__y` does not exist at all - the lookup's own not-found
    # message keeps the three-stanza shape, still at the quoted key's
    # value token.
    text.must_include("Error while resolving value for '{{ item }}': No variable named '__y' was found.\nOrigin: #{layout}:9:19")
    text.scan("'undef_y' is undefined\nOrigin").size.must_equal(1)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end
end
