require "../minitest_helper"

# ansible-core 2.21 labels a raising changed_when:/failed_when: with the
# clause that raised and renders the same three-part [ERROR] block the
# when: evaluator uses (live-verified vs 2.21.6):
#
#   [ERROR]: Task failed: Action failed: A 'changed_when' expression
#            failed: <detail>
#   Task failed: Action failed.
#   Origin: <task name line>
#   <<< caused by >>>
#   A 'changed_when' expression failed: <detail>
#   Origin: <clause value token>
#
# A module that had already failed keeps its own msg and shows
# "Module failed" in the block, and real moves that result's traceback
# placeholder into `<clause>_when_suppressed_exception`. The non-boolean
# class shortens the middle link and adds the detail as a third record
# (with the ALLOW_BROKEN_CONDITIONALS hint). An until: non-boolean result
# carries the clause's own "at '<file>:line:col>'" lineage.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_clause_playbook(yaml : String)
  playbook = File.tempname("conditional-clause-shape", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s, playbook}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "clause-labelled changed_when:/failed_when: failures" do
  it "labels a raising changed_when on a healthy result and keeps the module msg out of it" do
    status, output, playbook = run_clause_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: probe
          ansible.builtin.command:
            cmd: echo hi
          changed_when: broken_var.missingattr
          ignore_errors: true
    YAML

    status.exit_code.must_equal(0)
    clause = "Task failed: Action failed: A 'changed_when' expression failed: Error while evaluating conditional: 'broken_var' is undefined"
    output.must_include("[ERROR]: #{clause}")
    output.must_include("\nTask failed: Action failed.\nOrigin: #{playbook}:5:7")
    output.must_include("<<< caused by >>>\n\nA 'changed_when' expression failed: Error while evaluating conditional: 'broken_var' is undefined\nOrigin: #{playbook}:8:21")
    output.must_include(%("changed_when_result": "Error while evaluating conditional: 'broken_var' is undefined"))
    output.must_include(%("msg": "#{clause}"))
  end

  it "keeps the module's own msg when it has one" do
    _status, output, _playbook = run_clause_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: probe
          ansible.builtin.debug:
            msg: hello
          changed_when: broken_var.missingattr
          ignore_errors: true
    YAML

    output.must_include(%("msg": "hello"))
    output.wont_include(%("msg": "Task failed: Action failed: A 'changed_when'"))
  end

  it "shows Module failed for an already-failed module and moves the traceback marker" do
    _status, output, _playbook = run_clause_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: probe
          ansible.builtin.command:
            cmd: /bin/false
          failed_when: broken_var.missingattr
          ignore_errors: true
    YAML

    clause = "Task failed: Module failed: A 'failed_when' expression failed: Error while evaluating conditional: 'broken_var' is undefined"
    output.must_include("[ERROR]: #{clause}")
    output.must_include(%("failed_when_suppressed_exception": "(traceback unavailable)"))
    output.must_include(%("msg": "The command exited with a non-zero return code."))
    output.wont_include(%("msg": "#{clause}"))
  end

  it "renders the non-boolean class with a shortened middle link, a third record and the hint" do
    _status, output, playbook = run_clause_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: probe
          ansible.builtin.command:
            cmd: echo hi
          register: r
          changed_when: r.stdout
          ignore_errors: true
    YAML

    output.must_include("[ERROR]: Task failed: Action failed: A 'changed_when' expression failed: Conditional result (True) was derived from value of type 'str' at '#{playbook}:9:21'")
    output.must_include("<<< caused by >>>\n\nA 'changed_when' expression failed.\nOrigin: #{playbook}:9:21")
    output.must_include("<<< caused by >>>\n\nConditional result (True) was derived from value of type 'str' at '#{playbook}:9:21'. Conditionals must have a boolean result.\nOrigin: #{playbook}:9:21")
    output.must_include("Broken conditionals can be temporarily allowed with the `ALLOW_BROKEN_CONDITIONALS` configuration option.")
  end

  it "labels an until: evaluation failure and decorates a non-boolean result with the clause position" do
    _status, output, playbook = run_clause_playbook(<<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: probe
          ansible.builtin.command:
            cmd: echo hi
          register: r
          until: r.stdout
          retries: 1
          delay: 0
          ignore_errors: true
    YAML

    output.must_include("[ERROR]: Task failed: An 'until' expression failed: Conditional result (True) was derived from value of type 'str' at '#{playbook}:9:14'. Conditionals must have a boolean result.")
    output.must_include("<<< caused by >>>\n\nAn 'until' expression failed.\nOrigin: #{playbook}:9:14")
  end
end
