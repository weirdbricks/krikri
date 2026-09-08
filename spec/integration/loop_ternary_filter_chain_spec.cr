require "../spec_helper"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# ExpressionEvaluator#evaluate's ternary handling feeding into
# TaskExecutor#resolve_loop_template, private methods not reachable
# from a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("loop-ternary-filter-chain-spec", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "loop: source is an inline ternary whose chosen branch is a filter chain producing an Array" do
  it "iterates over the real list, not one item holding the whole unparsed string" do
    # Real bug found via RedHatOfficial.rhel8_pci_dss's own "Set
    # gpgcheck=1 for each yum repo" task: `loop: "{{ x | regex_findall
    # (...) if y is not skipped else [] }}"`. ExpressionEvaluator#evaluate
    # delegated the whole ternary to Crinja's plain #render! (Python-repr
    # stringification, e.g. "[['a.repo', 'sec1']]", single-quoted - not
    # valid JSON), so #resolve_loop_template's own `JSON.parse` of the
    # result failed and the array-wrapped fallback turned the WHOLE
    # unparsed repr string into ONE loop item instead of the real list -
    # `item[0]` then indexed into a String, "'item[0]' is undefined".
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: shell
            ansible.builtin.shell: printf 'a.repo:[sec1]\\nb.repo:[sec2]\\n'
            register: grep_results
            changed_when: false
          - name: loop with ternary over a filter-chain-produced array
            ansible.builtin.debug:
              msg: "{{ item[0] }}/{{ item[1] }}"
            loop: '{{ grep_results.stdout | regex_findall(''(.+\\.repo):\\[(.+)\\]\\n?'') if grep_results is not skipped else [] }}'
            register: loop_result
          - name: assert
            ansible.builtin.assert:
              that:
                - loop_result.results | length == 2
                - loop_result.results[0].msg == "a.repo/sec1"
                - loop_result.results[1].msg == "b.repo/sec2"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end
end
