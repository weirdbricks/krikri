require "../minitest_helper"

# yum/dnf's backend-resolution failure is a RETURNED dict in real's dnf
# ACTION plugin (`result.update({'failed': True, 'msg': ...})` in dnf.py),
# not a raise - so the executor's until:/retries: attempt loop treats it as
# an ordinary failed result and retries it, instead of taking the
# action-level escape (issue #131's raised-failure path, live-verified vs
# 2.19.11): the RETRYING line prints per attempt and the final result keeps
# the attempts key, while the [ERROR] block still reads "Action failed:".
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "yum action-level failure under until/retries" do
  it "retries the dnf backend-resolution failure like an ordinary failure" do
    playbook = File.tempname("yum-action-fail-until", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          ansible_pkg_mgr: apt
        tasks:
          - name: Install repo
            yum:
              name: krikri-nonexistent-package
              state: present
            until: false
            retries: 1
            delay: 0
            ignore_errors: true
            register: r
          - debug:
              msg: "{{ r | to_json }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("FAILED - RETRYING: [localhost]: Install repo (1 retries left).")
    text.must_include("[ERROR]: Task failed: Action failed: ('Could not detect which major revision of dnf is in use")
    # The fatal dump and the registered shape both carry the attempt-loop
    # bookkeeping (attempts, the error-event exception) the escape path
    # would have dropped.
    text.must_include(%("attempts": 1, "changed": false, "msg": ["Could not detect which major revision of dnf is in use))
    text.must_include(%q(\"exception\": \"(traceback unavailable)\", \"attempts\": 1}))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
