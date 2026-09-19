require "../spec_helper"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) for the same reason as with_nested_spec.cr:
# TaskExecutor#resolve_loop_together is a private method only reachable
# through a full run.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("with-together-spec", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "with_together: templated scalar sources" do
  it "zips {{ var }} sources elementwise with null padding on the shorter list" do
    # Round 700096/820006 (manala.accounts): with_together: was entirely
    # unimplemented - the keyword never appeared in the parser's loop
    # dispatch at all, so a task using it either errored or was silently
    # mishandled. Real Ansible zips the sources elementwise
    # (itertools.zip_longest), padding shorter lists with null, with
    # access via item.0/item.1/...
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          name_list: [alice, bob, carol]
          group_list: [dev]
        tasks:
          - name: together loop
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_together:
              - "{{ name_list }}"
              - "{{ group_list }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results | length == 3
                - result.results[0].msg == "alice-dev"
                - result.results[1].item[1] is none
                - result.results[2].item[0] == "carol"
      YAML

    status.success?.should be_true
    output.should contain("All assertions passed")
  end

  it "skips the whole task cleanly when both sources resolve to empty lists" do
    # The exact manala.accounts trigger shape: manala_accounts_users (and
    # its companion list) default to [], so every looped task must skip
    # with zero iterations - not error, not run once with an unbound item.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          name_list: []
          group_list: []
        tasks:
          - name: together loop over empty lists
            ansible.builtin.debug:
              msg: "{{ item.0 }}-{{ item.1 }}"
            with_together:
              - "{{ name_list }}"
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
end
