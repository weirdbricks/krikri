require "../minitest_helper"

# An unavailable module's task args are still finalized - ansible's order
# is when: -> arg finalization -> module resolution - so an undefined
# variable in the args of a task whose module krikri doesn't implement is
# a real "Finalization of task args ... failed" fatal, NOT a silent skip.
# Round 5210000: centralpayment.rhel-subscription's
# community.general.redhat_subscription with an undefined
# redhat_password - krikri skipped the task (skipped=1, failed=0), real
# ansible-playbook 2.19.11 failed it (fatal line above, failed=1). The
# unavailable-module skip now happens after arg finalization on the solo
# task path, with when_passes? deferring it there.
#
# Live-verified against ansible-core 2.19.11 locally: the failing shape
# below is byte-identical to real's output.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("unavailable-module-args", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "unavailable module args finalization" do
  it "fails the task on undefined args instead of skipping" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on unknown module
            community.general.redhat_subscription: state=present password={{ redhat_password }}
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    # rc=4 is this engine's documented convention for a genuinely-reached
    # unported module (pre-existing, unchanged by this fix) - real ansible
    # would exit 2, but the MESSAGE parity is what this test pins down.
    status.exit_code.must_equal(4)
    output.must_include("Finalization of task args for 'community.general.redhat_subscription' failed: Error while resolving value for 'password': 'redhat_password' is undefined")
    output.must_include("failed=1")
    output.wont_include("skipped=1")
    # A failed task halts the host, so the sentinel task never runs -
    # matches real ansible (ok=0 in the live-captured run).
    output.wont_include("SHOULD-RUN-AFTER")
  end

  it "still skips an unavailable module whose args are clean" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: clean args on unknown module
            community.general.redhat_subscription: state=present
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    # Same rc=4 convention as above; the point is skip-not-fail parity.
    status.exit_code.must_equal(4)
    output.must_include("skipped=1")
    output.wont_include("failed=1")
    output.must_include("SHOULD-RUN-AFTER")
  end

  it "still skips an unavailable module whose when: is false without finalizing args" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: false when on unknown module
            community.general.redhat_subscription: state=present password={{ redhat_password }}
            when: false
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
