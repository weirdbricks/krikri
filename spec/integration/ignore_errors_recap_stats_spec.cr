require "../spec_helper"

# Real Ansible's own strategy/__init__.py counts a failed task caught by
# ignore_errors: true as `ok` AND `ignored` in the recap - never
# `failed`, and never halts the host. TaskExecutor's shared
# ResultDisplay.update_stats already did this correctly for the common
# module-dispatch path, but several controller-side failure helpers
# (finish_include_vars_failure, execute_validate_argument_spec, and
# fail_include - used by include_tasks:/include_role:/import_* for a
# missing file, bad YAML shape, or load error) each had their OWN
# unconditional `failed += 1`, never consulting ignore_errors: for
# their own stats (only for whether to halt the host). Found via
# CyVerse-Ansible.ez's own "include variables ..., if error, just
# ignore" task (`ignore_errors: yes` on a missing-file include_vars:):
# real Ansible's recap showed `ok=10 failed=0 ignored=1`, this engine's
# showed `ok=9 failed=1 ignored=0`.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("ignore-errors-recap", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "ignore_errors: on a controller-side failure counts as ok+ignored, not failed" do
  it "include_vars: on a missing file, ignore_errors: true" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include vars that dont exist, ignored
            include_vars:
              file: "/nonexistent/does-not-exist-#{Random.rand(1_000_000)}.yml"
            ignore_errors: true
          - name: still runs after
            debug:
              msg: still going
      YAML

    status.success?.should be_true
    output.should contain("still going")
    output.should match(/failed=0\b/)
    output.should match(/ignored=1\b/)
  end

  it "include_tasks: on a missing file, ignore_errors: true" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include a file that doesn't exist, ignored
            include_tasks: "/nonexistent/does-not-exist-#{Random.rand(1_000_000)}.yml"
            ignore_errors: true
          - name: still runs after
            debug:
              msg: still going
      YAML

    status.success?.should be_true
    output.should contain("still going")
    output.should match(/failed=0\b/)
    output.should match(/ignored=1\b/)
  end

  it "include_vars: on a missing file, WITHOUT ignore_errors:, still fails and halts" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include vars that dont exist, not ignored
            include_vars:
              file: "/nonexistent/does-not-exist-#{Random.rand(1_000_000)}.yml"
          - name: should not run
            debug:
              msg: SHOULD_NOT_RUN
      YAML

    status.success?.should be_false
    output.should_not contain("SHOULD_NOT_RUN")
    output.should match(/failed=1\b/)
    output.should match(/ignored=0\b/)
  end
end

# Recap tallying for the implicit Gathering Facts task + ignore_errors:
# interactions, verified live against real ansible-core 2.19.11 (both by
# running ansible-playbook and by instrumenting its own
# AggregateStats.increment). Found via round900836 NINEJKH.git: facts +
# one ignore_errors:-swallowed command failure recapped ok=2 changed=1
# here vs real ok=1 - the phantom ok came from counting the implicit
# facts task, which real Ansible's recap never credits (an ignored
# failure's own ok/ignored/changed counting was already correct).
describe "PLAY RECAP tallying for implicit facts and ignored failures" do
  it "a successful implicit Gathering Facts task adds no ok to the recap" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: the only ok task
            debug:
              msg: hi
      YAML

    status.success?.should be_true
    output.should match(/ok=1\b/)
  end

  it "a failed-and-ignored command task counts ok+ignored, never failed, and facts add no ok" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: fail but ignore it
            command: /bin/false
            ignore_errors: true
      YAML

    status.success?.should be_true
    # Real 2.19.11 recaps exactly ok=1 changed=1 ignored=1 here: the
    # ignored failure itself is the one ok (the implicit facts task adds
    # nothing), and the command module reports changed=true on a
    # non-zero rc, which the ignored tally carries into `changed=`.
    output.should match(/ok=1\b/)
    output.should match(/changed=1\b/)
    output.should match(/failed=0\b/)
    output.should match(/ignored=1\b/)
  end

  it "a changed-then-failed-but-ignored task still counts changed" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: succeeds, then failed_when flips it, then ignored
            command: /bin/true
            failed_when: true
            ignore_errors: true
      YAML

    status.success?.should be_true
    # Real 2.19.11 recaps ok=1 changed=1 ignored=1 for exactly this
    # shape (verified live): the task DID change, so `changed=` counts
    # even though the task failed, and the ignored failure counts as ok
    # + ignored, never failed - update_stats' overlapping-counter
    # semantics must hold for the changed-and-then-ignored combination,
    # not just the plain-failure one.
    output.should match(/ok=1\b/)
    output.should match(/changed=1\b/)
    output.should match(/failed=0\b/)
    output.should match(/ignored=1\b/)
  end
end
