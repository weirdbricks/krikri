require "file_utils"
require "../spec_helper"

# Runs the compiled binary against real playbooks, since the bug is in
# the executor's controller-side with_subelements: source resolution
# (resolve_loop_subelements), not reachable from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Real bug found via a live 100-role confirm round: GROG.authorized-key's
# own idiom - `with_subelements: - "{{ authorized_key_list_all |
# selectattr('authorized_keys', 'defined') | list }}" - authorized_keys`
# - failed with "'item' is undefined" on an empty source list instead of
# correctly skipping (real Ansible: skipped=1). resolve_template_value
# only understands a bare/dotted variable reference; a filter chain
# doesn't match its regex and returned nil immediately - not because
# the list was empty, but because it was never evaluated - which fell
# out of the whole loop-resolver chain, so the task wasn't treated as a
# loop at all and ran once with `item` unbound.
describe "with_subelements: with a filter-chain source" do
  it "skips (not fails) when the filtered source list is empty" do
    playbook = File.tempname("with-subelements-empty", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mylist: []
        tasks:
          - name: manage
            ansible.builtin.debug:
              msg: "item={{ item }}"
            with_subelements:
              - "{{ mylist | selectattr('authorized_keys', 'defined') | list }}"
              - authorized_keys
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("skipping: [localhost]")
    output.to_s.should match(/skipped=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "iterates parent/subelement pairs correctly when the filtered source list is non-empty" do
    playbook = File.tempname("with-subelements-nonempty", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mylist:
            - name: foo
              authorized_keys:
                - key: "ssh-rsa AAA"
        tasks:
          - name: manage
            ansible.builtin.debug:
              msg: "parent={{ item.0.name }} key={{ item.1.key }}"
            with_subelements:
              - "{{ mylist | selectattr('authorized_keys', 'defined') | list }}"
              - authorized_keys
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("parent=foo key=ssh-rsa AAA")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
