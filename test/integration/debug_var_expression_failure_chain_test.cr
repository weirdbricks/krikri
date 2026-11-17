require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# ansible-core evaluates debug's `var:` as a Jinja expression inside the
# action plugin, so a failure there is an uncaught controller-side exception:
# the fatal msg carries the "Task failed: " wrapper, the [ERROR] block is the
# action-level chain whose cause sits at the `var:` VALUE token, and the
# fatal dump is msg-only (the registered result keeps changed: false).
# krikri used to report these as a bare "Action failed: <inner>" with
# changed: false in the dump, which every `debug: var:` failure diverged on
# (issue #1443).
describe "debug: var expression failures use ansible's action-level chain" do
  it "wraps a lazy value's lookup failure and dumps the fatal line msg-only" do
    playbook = File.tempname("debug-var-lookup-fail", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: lookup var
            ansible.builtin.debug:
              var: kpg_lookup_task_value
            register: r
            ignore_errors: true
            vars:
              kpg_lookup_task_value: '{{ lookup(''kpg_list'') }}'
          - name: show register
            ansible.builtin.debug:
              var: r
            ignore_errors: true
      YAML

    output = IO::Memory.new
    Process.run(BINARY, [playbook], output: output, error: output)
    text = output.to_s

    # Header, cause and the registered result's msg all read the same
    # framing (ansible prints the first two, then the register dump).
    text.scan("Task failed: Error while resolving `var` expression: The lookup plugin 'kpg_list' was not found.").size.must_equal(3)
    text.wont_include("Action failed:")
    text.must_include("Origin: #{playbook}:5:7\n")
    text.must_include("Error while resolving `var` expression: The lookup plugin 'kpg_list' was not found.\nOrigin: #{playbook}:7:14\n")
    # The variable's own definition carries no template origin for this
    # failure (the lookup only fails when rendered), so the chain must stop
    # at the var: value instead of fanning out to the definition on line 11.
    text.wont_include("Origin: #{playbook}:11:")

    # The fatal dump is msg-only, like every task-level debug failure.
    text.must_include(%(fatal: [localhost]: FAILED! => {"msg": "Task failed: Error while resolving `var` expression: The lookup plugin 'kpg_list' was not found."}))
    text.wont_include(%({"changed": false, "msg": "Task failed: Error while resolving `var` expression))

    # ... while the registered result still carries changed: false (real's
    # register shape, live-verified vs 2.21.6).
    text.must_include(%("changed": false))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "chains one segment deeper to the variable's own definition when its template is what raises" do
    playbook = File.tempname("debug-var-do-tag", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          do_tag: "{% set files = [] %}{% do files.append(1) %}{{ files }}"
        tasks:
          - name: do tag var
            ansible.builtin.debug:
              var: do_tag
            ignore_errors: true
      YAML

    output = IO::Memory.new
    Process.run(BINARY, [playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Error while resolving `var` expression: Syntax error in template: Encountered unknown tag 'do'.")
    # Second segment shortens to the framing alone and keeps the var: value
    # origin; the third is the inner error at the value's DEFINITION (the
    # same linkage real's {% do %} chain shows).
    text.must_include("<<< caused by >>>\n\nError while resolving `var` expression.\nOrigin: #{playbook}:9:14\n")
    text.must_include("<<< caused by >>>\n\nSyntax error in template: Encountered unknown tag 'do'.\nOrigin: #{playbook}:5:13\n")
    text.must_include(%(fatal: [localhost]: FAILED! => {"msg": "Task failed: Error while resolving `var` expression: Syntax error in template: Encountered unknown tag 'do'."}))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
