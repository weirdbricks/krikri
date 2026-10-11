require "../minitest_helper"

# A LOOPED task's args are finalized per item, after the when: - ansible's
# order is when: -> arg finalization -> module resolution, per loop item -
# so an undefined variable in the args of a looped task whose module krikri
# doesn't implement is a real "Finalization of task args ... failed" fatal
# for that item, NOT a silent skip. Round 5460184: CiscoUcs.ucs's looped
# cisco.ucs.ucs_timezone/ucs_ntp_server tasks all carry
# `hostname: "{{ ucs_hostname }}"` with that var undefined - krikri skipped
# every item (skipped=1, failed=0) and only died later on a genuinely
# unresolvable module name deeper in the role (real also refuses THAT one
# at include expansion - live-verified - but it never got there because the
# timezone task failed first, rc=2 ok=3 failed=1). The looped path's
# per-item when: pre-check now defers the unavailable-module skip so
# execute_task_once finalizes the args first, exactly like the solo task
# path since round 5210000.
#
# The controller collection-awareness check (0.9.1606) refuses a name
# neither krikri nor the controller can run, so these specs pin the lazy
# unavailable-module flow against a CONTROLLLED controller: the spawned
# binary gets ANSIBLE_COLLECTIONS_PATH pointed at a fixture tree whose
# community.general ships a redhat_subscription module file (same pattern
# as unavailable_module_args_finalization_test.cr).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("unavailable-module-loop", ".yml")
  File.write(playbook, yaml)
  fixture_root = File.tempname("unavailable-module-loop-collections")
  module_dir = File.join(fixture_root, "ansible_collections", "community", "general", "plugins", "modules")
  FileUtils.mkdir_p(module_dir)
  File.write(File.join(module_dir, "redhat_subscription.py"), "#!/usr/bin/python\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
    env: {"ANSIBLE_COLLECTIONS_PATH" => fixture_root})
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  FileUtils.rm_r(fixture_root) if fixture_root && Dir.exists?(fixture_root)
end

describe "unavailable module looped args finalization" do
  it "fails the looped item on undefined args instead of skipping" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on looped unknown module
            community.general.redhat_subscription: state=present password={{ redhat_password }}
            when: item.name is defined
            with_items:
            - name: x
            - name: y
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    # Real ansible 2.19.11 fails the task (rc=2, failed=1); a genuinely
    # reached module was never resolved because finalization precedes
    # module resolution, so this is NOT the engine-limit exit-4.
    status.exit_code.must_equal(2)
    output.must_include("Finalization of task args for 'community.general.redhat_subscription' failed: Error while resolving value for 'password': 'redhat_password' is undefined")
    output.must_include("failed=1")
    output.wont_include("skipped=1")
    # A failed task halts the host, so the sentinel task never runs -
    # matches real ansible.
    output.wont_include("SHOULD-RUN-AFTER")
  end

  it "still skips a looped unavailable module whose args are clean" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: clean args on looped unknown module
            community.general.redhat_subscription: state=present
            when: item.name is defined
            with_items:
            - name: x
            - name: y
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    # rc=4 is this engine's documented convention for a genuinely-reached
    # unported module (pre-existing, unchanged by this fix) - real ansible
    # would exit 2 with its own "couldn't resolve" at execution, but the
    # skip-not-fail parity is what this test pins down.
    status.exit_code.must_equal(4)
    output.must_include("skipped=1")
    output.wont_include("failed=1")
    # Per-item skipping lines still print, one per item, with the label.
    output.must_include("skipping: [")
    output.must_include("(item={'name': 'x'})")
    output.must_include("(item={'name': 'y'})")
    output.must_include("SHOULD-RUN-AFTER")
  end

  it "still skips a looped unavailable module whose when: is false without finalizing args" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: false when on looped unknown module
            community.general.redhat_subscription: state=present password={{ redhat_password }}
            when: false
            with_items: [a]
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(0)
    output.must_include("skipped=1")
    output.wont_include("failed=1")
    output.must_include("SHOULD-RUN-AFTER")
  end
end
