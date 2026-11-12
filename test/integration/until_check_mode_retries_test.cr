require "../minitest_helper"

# The until:/retries: attempt loop runs in CHECK MODE too (issue #1175,
# adipriyantobpn.repo-remi's --check round: real printed five
# FAILED - RETRYING lines and a fatal carrying the attempts key while
# this engine's check-mode gate skipped the whole loop, so a
# check-mode run diverged from ansible-playbook byte for byte). Two
# shapes pin the loop's check-mode engagement here (a failing task and
# the module-level check-mode skip whose until: passes), plus the one
# shape that must stay OUT of it: an ACTION-level check-mode skip is
# Ansible's AnsibleActionSkip (ActionBase#run's _supports_check_mode
# gate), which leaves the whole attempt loop before it can retry - one
# run, no FAILED - RETRYING lines and no attempts key (live-verified
# vs 2.21.6).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, check : Bool = false)
  playbook = File.tempname("until-check-mode", ".yml")
  File.write(playbook, yaml)
  args = ["-i", INVENTORY]
  args << "--check" if check
  args << playbook
  output = IO::Memory.new
  status = Process.run(BINARY, args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "until/retries attempt loop in check mode" do
  it "retries a failing task with FAILED - RETRYING lines and an attempts key" do
    status, output = run_playbook(<<-YAML, check: true)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: fail repeatedly
            fail:
              msg: boom
            register: r
            until: '"failed" not in r'
            retries: 3
            delay: 0
      YAML

    status.exit_code.must_equal(2)
    # 2.21 counts the retries REMAINING AFTER each line (retries: 3
    # prints 2, 1, 0) and stamps the exhausted result with the retries
    # count - exactly the shape real printed for the role's yum task.
    output.must_include("FAILED - RETRYING: [localhost]: fail repeatedly (2 retries left).")
    output.must_include("FAILED - RETRYING: [localhost]: fail repeatedly (1 retries left).")
    output.must_include("FAILED - RETRYING: [localhost]: fail repeatedly (0 retries left).")
    output.wont_include("(-1 retries left)")
    output.must_include(%(fatal: [localhost]: FAILED! => {"attempts": 3, "changed": false, "msg": "boom"}))
    output.must_include("failed=1")
  end

  it "stamps the attempts key on a check-mode module skip whose until passes" do
    status, output = run_playbook(<<-YAML, check: true)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: skipped in check mode
            command: /bin/true
            register: r
            until: r is not failed
            retries: 3
            delay: 0
          - debug:
              msg: "{{ r | to_json }}"
      YAML

    status.exit_code.must_equal(0)
    # Real's command check-mode skip is an ordinary returned result, so
    # the attempt loop evaluates until: against it and stamps the
    # passing attempt's 1-based number on the registered result - while
    # the status line stays Ansible's bare "skipping:" and the recap
    # books skipped=, never ok=.
    output.must_include("skipping: [localhost]")
    output.must_include("skipped=1")
    output.wont_include("FAILED - RETRYING")
    output.must_include(%(\\"attempts\\": 1))
  end

  it "runs a check-mode action-level skip exactly once with no attempts key" do
    status, output = run_playbook(<<-YAML, check: true)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: action skip never passes
            uri:
              url: http://127.0.0.1:1/
            register: r
            until: 1 == 2
            retries: 2
            delay: 0
          - debug:
              msg: "{{ r | to_json }}"
      YAML

    status.exit_code.must_equal(0)
    # uri's check-mode skip is ActionBase#run RAISING AnsibleActionSkip,
    # and the raise exits the whole attempt loop on the first pass: no
    # FAILED - RETRYING lines, no attempts key anywhere, one skip
    # counted - whatever the until: says.
    output.must_include("skipping: [localhost]")
    output.must_include("skipped=1")
    output.wont_include("FAILED - RETRYING")
    output.wont_include("attempts")
  end
end
