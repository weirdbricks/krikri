require "../minitest_helper"
require "file_utils"

# A filter/test plugin's RUNTIME failure inside a `when:` conditional is
# ansible-core 2.19's conditional-evaluation display class, not a bare
# fatal line (issue #247, lotusnoir.apps_consul_exporter):
#
#     when:
#       - (params | length > 0)
#
# with a first_found no-match None prints the same two-level [ERROR]
# chain block as the other conditional wordings - task Origin, then
# "<<< caused by >>>" with the filter message Origin'd at the `when:`
# LIST ITEM's own value token (column 11 for an 8-space-indented
# `- (params | length > 0)`) - and the fatal line is the
# "Task failed: "-prefixed {"msg": ...} JSON. No
# ALLOW_BROKEN_CONDITIONALS hint: the block ends at the Origin frame.
# Live-compared byte for byte with ansible-playbook 2.19.11.
#
# This applies to EVERY statement family whose `when:` rides the same
# funnel too - include_vars: (the real role's actual task shape), role-
# sourced tasks (the Origin points into the role's own tasks/main.yml) -
# and every module class keeps its own fatal dump (include_vars: carries
# changed: false, unlike a debug: task's msg-only shape).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, cwd : String? = nil)
  playbook = File.tempname("when-filter-chain", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: cwd)
  {status, output.to_s, playbook}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "when: filter-plugin runtime failure chain" do
  it "prints real's two-level chain block with the when: list item's Origin" do
    status, output, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          params: "{{ lookup('first_found', dict(files=['no-such-file-here.yml'], paths=['/tmp']), errors='ignore') }}"
        tasks:
          - name: Show params
            debug: msg=ran
            when:
              - (params | length > 0)
      YAML

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: The filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()")
    # the chain: task Origin, then the failing when: list item's own
    # value token (caret at column 11, under the text after "- ")
    output.must_include("Task failed.\nOrigin: ")
    output.must_include("<<< caused by >>>\n\nThe filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()\nOrigin: ")
    output.must_include("- (params | length > 0)\n             ^ column 11")
    # fatal line is the JSON shape, msg-only for a debug: task
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: The filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()\"}")
    output.wont_include("ALLOW_BROKEN_CONDITIONALS")
    output.wont_include("Unhandled exception")
  end

  it "prints real's chain for a scalar when: with a test-plugin failure" do
    status, output, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ver: not-a-version
        tasks:
          - name: Version check
            debug: msg=ran
            when: "ver is version('1.0', '>=')"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: The test plugin 'ansible.builtin.version' failed: Version comparison failed: '<' not supported between instances of 'str' and 'int'")
    output.must_include("<<< caused by >>>\n\nThe test plugin 'ansible.builtin.version' failed: Version comparison failed: '<' not supported between instances of 'str' and 'int'\nOrigin: ")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: The test plugin 'ansible.builtin.version' failed: Version comparison failed: '<' not supported between instances of 'str' and 'int'\"}")
    output.wont_include("ALLOW_BROKEN_CONDITIONALS")
  end

  # The same filter-plugin wording raised from a TASK ARG (not a when:)
  # keeps its own finalization-chain display - the when:-failure marker
  # on the result must not suppress that path.
  it "keeps the task-arg finalization chain for a non-when filter failure" do
    status, output, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Arg failure
            debug:
              msg: "{{ definitely_missing | mandatory }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': The filter plugin 'ansible.builtin.mandatory' failed: Mandatory variable 'definitely_missing' not defined")
    output.must_include("<<< caused by >>>")
  end

  # The real role's task shape: `include_vars: "{{ params }}"` whose
  # vars: block's first_found value feeds the when: AND whose vars: map
  # holds a nested list (`files:`) BETWEEN the task and the when: - the
  # origin scan used to stop at that list's own `- "..."` line before
  # ever reaching `when:` and silently dropped the whole block here
  # (issue #247's real-role report). include_vars: also keeps the
  # module-keyed changed:false fatal dump, unlike a debug: task's.
  it "prints real's chain for a failing when: on include_vars: with a vars: list before when:" do
    status, output, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Gather OS specific variables
            ansible.builtin.include_vars: "{{ params }}"
            vars:
              params_:
                files:
                  - "nosuch.yml"
                paths:
                  - vars
              params: "{{ lookup('first_found', params_, errors='ignore') }}"
            when:
              - (params | length > 0)
            tags: always
      YAML

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: The filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()")
    output.must_include("Task failed.\nOrigin: ")
    output.must_include("<<< caused by >>>\n\nThe filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()\nOrigin: ")
    output.must_include("- (params | length > 0)\n             ^ column 11")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: The filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()\"}")
    output.wont_include("ALLOW_BROKEN_CONDITIONALS")
  end

  # The same task inside a ROLE file: the Origins point into the role's
  # own tasks/main.yml (the `---` document header line the role files
  # carry stays in the code frame), not the playbook (live-compared byte
  # for byte with ansible-playbook 2.19.11 on an identical layout).
  it "prints real's chain with the role file's own Origin for a role-sourced include_vars task" do
    tempdir = File.tempname("when-chain-role").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "r1")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      ---
      - name: Gather OS specific variables
        ansible.builtin.include_vars: "{{ params }}"
        vars:
          params_:
            files:
              - "nosuch.yml"
            paths:
              - vars
          params: "{{ lookup('first_found', params_, errors='ignore') }}"
        when:
          - (params | length > 0)
        tags: always
      YAML
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - r1
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: The filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()\n\nTask failed.\nOrigin: #{tasks_file}:2:3")
    text.must_include("<<< caused by >>>\n\nThe filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()\nOrigin: #{tasks_file}:12:7")
    text.must_include("- (params | length > 0)\n         ^ column 7")
    text.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: The filter plugin 'ansible.builtin.length' failed: object of type 'NoneType' has no len()\"}")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
