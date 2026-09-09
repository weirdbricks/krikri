require "../spec_helper"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# TaskExecutor#resolve_loop_nested, a private method not reachable from
# a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("with-nested-spec", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "with_nested: templated scalar sources" do
  it "expands each {{ var }} source to its real list at runtime" do
    # Real bug found benchmarking gantsign.sdkman: the parser's
    # with_nested: branch wrapped every scalar entry - including a whole
    # `{{ var }}` list reference - as a ONE-element literal list at parse
    # time, pinning each cartesian factor to size 1 no matter how many
    # elements the variable actually held. The loop iterated once per
    # outer source with `item` = the whole rendered inner list, where
    # real Ansible iterates once per PAIR of elements.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          user_list: [alice, bob]
          group_list: [dev, ops]
        tasks:
          - name: nested loop
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_nested:
              - "{{ user_list }}"
              - "{{ group_list }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 4
                - result.results[0].msg == "alice-dev"
                - result.results[1].msg == "alice-ops"
                - result.results[2].msg == "bob-dev"
                - result.results[3].msg == "bob-ops"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end

  it "yields zero iterations when a templated source resolves to an empty list" do
    # The "including zero" half of the same root cause: an empty source
    # var made the parse-time pinning INVISIBLE (1x1 still ran), but the
    # runtime-resolved product must be 0 - task skipped, not run once
    # with a whole-list item.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          user_list: []
          group_list: [dev, ops]
        tasks:
          - name: nested loop over empty source
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_nested:
              - "{{ user_list }}"
              - "{{ group_list }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 0
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end

  it "keeps a mixed literal + templated source list working" do
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          group_list: [dev, ops]
        tasks:
          - name: nested loop, mixed sources
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_nested:
              - [alice, bob]
              - "{{ group_list }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 4
                - result.results[0].msg == "alice-dev"
                - result.results[3].msg == "bob-ops"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end
end
