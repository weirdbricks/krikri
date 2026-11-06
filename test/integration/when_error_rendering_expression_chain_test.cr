require "../minitest_helper"

# A `when:` whose evaluation fails at runtime - an ordering comparison
# between an int (a registered stdout through `| int`) and a quoted-string
# var - is real 2.19.11's conditional-failure display class: the two-level
# [ERROR] chain block ("Task failed." at the task's Origin, "<<< caused
# by >>>" with the error's Origin at the when: value token) and the
# "Task failed: A 'when' expression failed: Error rendering expression: ..." fatal msg, with no
# ALLOW_BROKEN_CONDITIONALS hint after the block (issue #799,
# ontic.redis's somaxconn sysctl task). Left out of the conditional-failure
# wording classes, the failure fell through to the generic module-failure
# chain instead: a bogus "Module failed: Task failed: " brief and no
# caused-by block at all.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "when: runtime expression failure chain" do
  it "prints the two-level caused-by chain with the Origin at the when: token" do
    playbook = PluginSpecHelper.tmp_path("playbook.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          backlog: '511'
        tasks:
          - name: read stdout
            command: /bin/true
            register: reg
            changed_when: false

          - name: gated task
            command: /bin/true
            when: 'reg.stdout | int < backlog'
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    text = output.to_s
    location = File.expand_path(playbook)
    text.must_include("[ERROR]: Task failed: A 'when' expression failed: Error rendering expression: '<' not supported between instances of 'int' and '_AnsibleTaggedStr'")
    text.must_include("Task failed.\nOrigin: #{location}:12:7")
    text.must_include("<<< caused by >>>\n\nA 'when' expression failed: Error rendering expression: '<' not supported between instances of 'int' and '_AnsibleTaggedStr'\nOrigin: #{location}:14:13")
    # The runtime-expression class ends the block at the Origin, like the
    # other compile/runtime wording classes.
    text.wont_include("Broken conditionals")
  end

  it "keeps the generic module-failure chain off the conditional failure" do
    playbook = PluginSpecHelper.tmp_path("playbook.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          backlog: '511'
        tasks:
          - name: read stdout
            command: /bin/true
            register: reg
            changed_when: false

          - name: gated task
            command: /bin/true
            when: 'reg.stdout | int < backlog'
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    text = output.to_s
    # The when: failure routes through emit_when_error_chain (whose block
    # the first test pins); the result's _ansible_when_error_emitted marker
    # must keep ResultDisplay's generic path from printing a second,
    # differently-shaped "Module failed: " block.
    text.wont_include("Module failed")
    text.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: A 'when' expression failed: Error rendering expression: '<' not supported between instances of 'int' and '_AnsibleTaggedStr'\"}")
    text.must_include("failed=1")
  end
end
