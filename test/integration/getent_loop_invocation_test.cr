require "../minitest_helper"

# Runs the compiled binary against a real playbook: this pins the
# interaction between the getent plugin's `invocation` block, the looped
# register aggregation (which must KEEP invocation on each results[]
# entry), and the non-looped register strip (which must drop it) - three
# pieces no single unit spec can see at once.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

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
    # The pulsar pattern reads per-item invocation, which under ansible-core
    # 2.21 exists only when INJECT_INVOCATION is enabled (its default is
    # off; see InvocationInjection) - run with the setting on, the same
    # way the real role would see invocation under a 2.19 controller.
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
      env: {"ANSIBLE_INJECT_INVOCATION" => "1"})

    status.success?.must_equal(true)
    text = output.to_s
    text.wont_include("None has no element")
    text.must_include("failed=0")
    # root's GID (field [2] of the passwd entry) is always 0 - the debug
    # task prints it on its own line.
    text.must_include("\"msg\": \"0\"")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "does not expose invocation on a NON-looped register while INJECT_INVOCATION is off" do
    # ansible-core 2.21 flipped INJECT_INVOCATION's default to false, and
    # relaxed the strategy's top-level register strip exactly when the
    # setting is on (live-verified vs 2.21.6: with it on a solo registered
    # stat/command result KEEPS `invocation`). With the setting at its
    # default (off) no module result carries `invocation` in the first
    # place, so the registered dict shows none - this pins the default-off
    # shape; the on-shape is pinned by the pulsar spec above (per-item)
    # and the solo-register coverage in the executor specs.
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

    status.success?.must_equal(true)
    text = output.to_s
    # a whole-span boolean expression prints as a native JSON bool on 2.19.11
    text.must_include(%("msg": false))
    text.wont_include(%("msg": true))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
