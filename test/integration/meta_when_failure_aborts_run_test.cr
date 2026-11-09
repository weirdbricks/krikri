require "../minitest_helper"

# ansible-core's strategy evaluates a meta: task's `when:` itself
# (strategy/__init__.py's _execute_meta -> task._resolve_conditional),
# outside the task executor that turns every other conditional failure
# into a failed task: a raise there propagates as a plain AnsibleError and
# takes the whole run down. Real prints one `[ERROR]:` line plus the
# failing clause's Origin block on stderr and exits 1 - no "Task failed."
# chain, no `fatal:` line, no PLAY RECAP, and no rescue even under
# `ignore_errors: true`. Every expectation below is live-verified against
# ansible-core 2.21.6 (issue #1007).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_meta_failure_play(playbook : String) : {Int32, String}
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
  {status.exit_code, output.to_s}
end

private def write_meta_failure_play(prefix : String, body : String) : String
  playbook = File.tempname(prefix, ".yml")
  File.write(playbook, body)
  playbook
end

describe "a meta task whose when: fails to evaluate" do
  it "aborts the run with the bare [ERROR] block, rc 1, and no recap" do
    playbook = write_meta_failure_play("meta-when-fatal", <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.meta: end_host
            when: some_undefined_var not in ["a", "b"]
      YAML
    code, text = run_meta_failure_play(playbook)

    code.must_equal(1)
    text.must_include("[ERROR]: Error while evaluating conditional: 'some_undefined_var' is undefined\n" \
                      "Origin: #{playbook}:5:13\n\n" \
                      "3   tasks:\n" \
                      "4     - ansible.builtin.meta: end_host\n" \
                      "5       when: some_undefined_var not in [\"a\", \"b\"]\n" \
                      "              ^ column 13\n")
    # A non-meta task's identical conditional failure is a failed TASK:
    # the clause-labelled chain, a fatal line and the recap must not
    # appear here.
    text.wont_include("Task failed:")
    text.wont_include("fatal:")
    text.wont_include("PLAY RECAP")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "ends with the non-boolean conditional's ALLOW_BROKEN_CONDITIONALS hint" do
    playbook = write_meta_failure_play("meta-when-nonbool", <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          some_list: [1, 2]
        tasks:
          - ansible.builtin.meta: end_host
            when: some_list
      YAML
    code, text = run_meta_failure_play(playbook)

    code.must_equal(1)
    text.must_include("[ERROR]: Conditional result (True) was derived from value of type 'list' at '#{playbook}:4:16'. " \
                      "Conditionals must have a boolean result.\nOrigin: #{playbook}:7:13\n")
    text.must_include("^ column 13\n\n" \
                      "Broken conditionals can be temporarily allowed with the `ALLOW_BROKEN_CONDITIONALS` configuration option.\n")
    text.wont_include("PLAY RECAP")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "cannot be rescued by ignore_errors, a block's inherited when:, or a when: list" do
    playbook = write_meta_failure_play("meta-when-shapes", <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.meta: end_host
            ignore_errors: true
            when: some_undefined_var not in ["a", "b"]
      YAML
    code, text = run_meta_failure_play(playbook)
    code.must_equal(1)
    text.must_include("Origin: #{playbook}:6:13")
    text.wont_include("PLAY RECAP")
    File.delete(playbook)

    playbook = write_meta_failure_play("meta-when-block", <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - block:
              - ansible.builtin.meta: end_host
            when: some_undefined_var not in ["a", "b"]
      YAML
    code, text = run_meta_failure_play(playbook)
    code.must_equal(1)
    text.must_include("Origin: #{playbook}:6:13")
    text.wont_include("PLAY RECAP")
    File.delete(playbook)

    # A when: LIST fails strict per CLAUSE, and real pins the Origin on
    # that clause's own item line.
    playbook = write_meta_failure_play("meta-when-list", <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.meta: end_host
            when:
              - true
              - some_undefined_var not in ["a", "b"]
      YAML
    code, text = run_meta_failure_play(playbook)
    code.must_equal(1)
    text.must_include("Origin: #{playbook}:7:11")
    text.wont_include("PLAY RECAP")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "aborts the run from inside an included file too" do
    inner = File.tempname("meta-when-fatal-inner", ".yml")
    File.write(inner, <<-YAML)
      - ansible.builtin.meta: end_host
        when: some_undefined_var not in ["a", "b"]
      YAML
    playbook = write_meta_failure_play("meta-when-include", <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.include_tasks: #{inner}
      YAML
    code, text = run_meta_failure_play(playbook)

    # The include's own load-failure rescue must not swallow the abort.
    code.must_equal(1)
    text.must_include("Origin: #{inner}:2:9")
    text.wont_include("Failed to load included tasks")
    text.wont_include("PLAY RECAP")
  ensure
    File.delete(inner) if inner && File.exists?(inner)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "leaves an ordinary task's identical conditional failure a failed task" do
    playbook = write_meta_failure_play("meta-when-ordinary-task", <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              msg: never
            when: some_undefined_var not in ["a", "b"]
      YAML
    code, text = run_meta_failure_play(playbook)

    code.must_equal(2)
    text.must_include("[ERROR]: Task failed: A 'when' expression failed: Error while evaluating conditional: " \
                      "'some_undefined_var' is undefined")
    text.must_include("fatal: [localhost]: FAILED! =>")
    text.must_include("PLAY RECAP")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
