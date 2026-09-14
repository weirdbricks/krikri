require "../spec_helper"

# Runs the compiled binary against a real playbook: this pins the
# interaction between the getent plugin's `invocation` block, the looped
# register aggregation (which must KEEP invocation on each results[]
# entry), and the non-looped register strip (which must drop it) - three
# pieces no single unit spec can see at once.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "looped+registered getent invocation" do
  it "lets a later task index ansible_facts via results[].invocation.module_args.key (galaxyproject.pulsar pattern)" do
    # Round 813375 (galaxyproject.pulsar): the role recovers each loop
    # item's ORIGINAL getent key via
    # `item.invocation.module_args.key`, then uses it to index that same
    # item's `ansible_facts.getent_passwd[...]`. Without the plugin's
    # invocation block the key resolved to None and `[2]` on the
    # resulting None crashed with "None has no element 2".
    playbook = File.tempname("getent-loop-invocation", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Get passwd entries
            getent:
              database: passwd
              key: "{{ item }}"
            with_items:
              - root
            register: passwd_result

          - name: Index via invocation.module_args.key like galaxyproject.pulsar does
            ansible.builtin.debug:
              msg: "{{ passwd_result.results[0].ansible_facts.getent_passwd[passwd_result.results[0].invocation.module_args.key][2] }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    text = output.to_s
    text.should_not contain("None has no element")
    text.should contain("failed=0")
    # root's GID (field [2] of the passwd entry) is always 0 - the debug
    # task prints it on its own line.
    text.should contain("\n  0\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "does not expose invocation on a NON-looped register (real Ansible's strategy strip)" do
    # Real ansible-core's strategy plugin deletes a top-level `invocation`
    # from the registered dict for a plain (non-looped) register, while a
    # looped register's per-item results[] entries keep theirs - pinned
    # above. Without this strip here, a registered getent result would
    # show an `invocation` key real Ansible never exposes.
    playbook = File.tempname("getent-noloop-invocation", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Get passwd entry
            getent:
              database: passwd
              key: root
            register: r

          - name: Show whether invocation survived the register
            ansible.builtin.debug:
              msg: "{{ 'invocation' in r }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    text = output.to_s
    text.should contain("False")
    text.should_not contain("True")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
