require "../minitest_helper"

# Ansible's own strategy/__init__.py counts a failed task caught by
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
# Ansible's recap showed `ok=10 failed=0 ignored=1`, this engine's
# showed `ok=9 failed=1 ignored=0`.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, extra_args : Array(String) = [] of String)
  playbook = File.tempname("ignore-errors-recap", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY] + extra_args + [playbook], output: output, error: output)
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

    status.success?.must_equal(true)
    output.must_include("still going")
    output.must_match(/failed=0\b/)
    output.must_match(/ignored=1\b/)
  end

  it "include_tasks: on a missing file fails fatally even under ignore_errors: (Ansible 2.21.6)" do
    # Live-verified against ansible-core 2.21.6 (this expectation used to
    # claim ok+ignored and "still going" - wrong): an include_tasks: whose
    # file resolves nowhere is a fatal include failure that ignore_errors:
    # does NOT apply to - the play halts for the host, failed=1 ignored=0,
    # rc=2, with the DataLoader error block on stdout and the msg-only
    # fatal dump after it.
    missing = "/nonexistent/does-not-exist-#{Random.rand(1_000_000)}.yml"
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include a file that doesn't exist
            include_tasks: "#{missing}"
            ignore_errors: true
          - name: still runs after
            debug:
              msg: still going
      YAML

    status.exit_code.must_equal(2)
    output.wont_include("still going")
    output.must_match(/failed=1\b/)
    output.must_match(/ignored=0\b/)
    output.must_include("{\"changed\": false, \"msg\": \"Unable to retrieve file contents. Could not find or access '#{missing}'")
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

    status.success?.must_equal(false)
    output.wont_include("SHOULD_NOT_RUN")
    output.must_match(/failed=1\b/)
    output.must_match(/ignored=0\b/)
  end
end

# Recap tallying for the implicit Gathering Facts task + ignore_errors:
# interactions, verified live against ansible-core 2.19.11 (run
# cache-free: this box's ambient ANSIBLE_GATHERING=smart + a warm
# /tmp/ansible_facts_cache makes Ansible silently SKIP Gathering
# Facts on a rerun - no banner, no recap contribution - which once got
# misread as "facts never count in the recap"). A successful implicit
# facts task counts ok=1 like any task; an ignore_errors:-swallowed
# failure counts ok + ignored (never failed), and its changed= still
# counts.
describe "PLAY RECAP tallying for implicit facts and ignored failures" do
  it "a successful implicit Gathering Facts task adds ok=1 to the recap" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: the only ok task
            debug:
              msg: hi
      YAML

    status.success?.must_equal(true)
    output.must_match(/ok=2\b/)
  end

  it "a failed-and-ignored command task counts ok+ignored, never failed, and facts add ok=1" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: fail but ignore it
            command: /bin/false
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    # Ansible 2.19.11 recaps exactly ok=2 changed=1 ignored=1 here
    # (verified live, cache-free): the ignored failure counts as one ok
    # + one ignored, the command module reports changed=true on a
    # non-zero rc, and the implicit facts task adds its own ok=1.
    output.must_match(/ok=2\b/)
    output.must_match(/changed=1\b/)
    output.must_match(/failed=0\b/)
    output.must_match(/ignored=1\b/)
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

    status.success?.must_equal(true)
    # Ansible 2.19.11 recaps ok=1 changed=1 ignored=1 for exactly this
    # shape (verified live, cache-free): the task DID change, so
    # `changed=` counts even though the task failed, and the ignored
    # failure counts as ok + ignored, never failed - update_stats'
    # overlapping-counter semantics must hold for the changed-and-then-
    # ignored combination, not just the plain-failure one.
    output.must_match(/ok=1\b/)
    output.must_match(/changed=1\b/)
    output.must_match(/failed=0\b/)
    output.must_match(/ignored=1\b/)
  end
end

# Issue #1112: a failing handler whose ignore_errors: resolves true must
# behave exactly like a failing task's - print a bare "...ignoring" after
# its fatal line and count ok + ignored in the recap, never failed. The
# handler-result recording step (HandlerRunner#record_handler_result)
# used to pass no ignore_errors at all to display_result/update_stats,
# so the handler printed no "...ignoring" and the recap showed failed=1
# where ansible-playbook shows ok+ignored (verified live against
# ansible-core 2.21.6 for every shape below).
describe "ignore_errors: on a failing handler counts ok+ignored like a task (issue #1112)" do
  it "a failing handler with plain ignore_errors: true prints ...ignoring and counts ok+ignored" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        handlers:
          - name: Failing handler
            ansible.builtin.fail:
              msg: handler failed on purpose
            ignore_errors: true
        tasks:
          - name: Trigger the handler
            ansible.builtin.command: /bin/true
            changed_when: true
            notify: Failing handler
      YAML

    status.success?.must_equal(true)
    output.must_include("handler failed on purpose")
    output.must_include("...ignoring")
    output.must_match(/ok=2\b/)
    output.must_match(/changed=1\b/)
    output.must_match(/failed=0\b/)
    output.must_match(/ignored=1\b/)
  end

  it "a failing looped handler under ignore_errors: prints ...ignoring once and counts ok+ignored" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        handlers:
          - name: Failing looped handler
            ansible.builtin.fail:
              msg: "handler item {{ item }} failed on purpose"
            loop:
              - one
              - two
            ignore_errors: true
        tasks:
          - name: Trigger the handler
            ansible.builtin.command: /bin/true
            changed_when: true
            notify: Failing looped handler
      YAML

    status.success?.must_equal(true)
    output.must_include("(item=one)")
    output.must_include("(item=two)")
    # Ansible prints the suffix once for the whole handler, after the
    # per-item failure lines - not per item.
    output.scan("...ignoring").size.must_equal(1)
    output.must_match(/ok=2\b/)
    output.must_match(/failed=0\b/)
    output.must_match(/ignored=1\b/)
  end

  it "the issue's check-mode repro (templated ignore_errors: '{{ ansible_check_mode }}') recaps ok=3 ignored=2" do
    status, output = run_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        handlers:
          - name: Failing handler
            ansible.builtin.fail:
              msg: handler failed on purpose
            ignore_errors: "{{ ansible_check_mode }}"
        tasks:
          - name: Trigger the handler
            ansible.builtin.command: /bin/true
            changed_when: true
            notify: Failing handler
            check_mode: false
          - name: Failing task with the same ignore_errors
            ansible.builtin.fail:
              msg: task failed on purpose
            ignore_errors: "{{ ansible_check_mode }}"
      YAML

    status.success?.must_equal(true)
    # Both failures are ignored in check mode - the task's suffix already
    # printed before the fix, the handler's was the missing one.
    output.scan("...ignoring").size.must_equal(2)
    output.must_match(/ok=3\b/)
    output.must_match(/changed=1\b/)
    output.must_match(/failed=0\b/)
    output.must_match(/ignored=2\b/)
  end
end
