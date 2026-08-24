require "../spec_helper"

# A genuinely undefined loop: source must FAIL the task at loop-resolution
# time, before the task body runs at all - real Ansible's behavior,
# captured live against ansible-core 2.19.12 on Rocky 9.6 (round174
# differential matrix; scenario numbers cited per example).
#
# Note real Ansible's wording here is a BARE "'x' is undefined" - it does
# NOT carry the "Error while evaluating conditional: " prefix its when:
# failures use (matrix scenario 13 vs 1). Real Ansible additionally wraps
# it in a generic "Task failed: " at the outer layer, exactly as it does
# for the when: case this engine already matches.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("loop-strict-undefined", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "undefined loop: source is strict" do
  # Scenario 1b - THE core bug. A task body that does NOT reference
  # `item` used to run once and SUCCEED (ok=1, exit 0). A body that DOES
  # reference item failed, but for the wrong reason ("'item' is
  # undefined"), which masked the gap in casual testing.
  it "fails, naming the loop-source variable, when the body does not reference item" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ undefined_var }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: "SENTINEL-SHOULD-NOT-RUN"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should_not contain("'item' is undefined")
    output.should_not contain("Error while evaluating conditional")
    output.should_not contain("SENTINEL-SHOULD-NOT-RUN")
    output.should contain("failed=1")
  end

  # Scenario 1 - body DOES reference item: must now name the loop source,
  # not `item`.
  it "names the loop-source variable even when the body references item" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should_not contain("'item' is undefined")
  end

  # Scenarios 3, 4, 6b, 5a, 5b - every loop form is strict. with_fileglob
  # and with_first_found are a SEPARATE code path that used to skip
  # cleanly rather than fail.
  it "is strict for with_items: too" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            with_items: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should_not contain("skipping:")
    output.should contain("failed=1")
  end

  it "is strict for with_dict: too" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            with_dict: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should_not contain("skipping:")
    output.should contain("failed=1")
  end

  it "is strict for with_community.general.flattened: too" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            with_community.general.flattened: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should_not contain("skipping:")
    output.should contain("failed=1")
  end

  it "is strict for with_fileglob: too" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            with_fileglob: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should_not contain("skipping:")
    output.should contain("failed=1")
  end

  it "is strict for with_first_found: too" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            with_first_found: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should_not contain("skipping:")
    output.should contain("failed=1")
  end

  # Scenario 2 - the lenient escape hatch. Same bare/dotted-only
  # strictness boundary the when: work uses.
  it "stays lenient for a default() filter chain" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ undefined_var | default([]) }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: "SENTINEL-OK"
      YAML

    status.success?.should be_true
    output.should contain("skipping:")
    output.should contain("SENTINEL-OK")
    output.should contain("failed=0")
  end

  # Scenario 7 - when: is evaluated BEFORE the loop source on both
  # engines, so a false when: skips cleanly and never touches the
  # undefined loop var.
  it "lets a false when: skip the task without touching the loop source" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ undefined_var }}"
            when: false
      YAML

    status.success?.should be_true
    output.should contain("skipping:")
    output.should_not contain("is undefined")
  end

  # buluma.mount's own assert.yml (round174). Real Ansible consults the
  # task's when: before treating an undefined loop source as fatal, and
  # a condition that REFERENCES the loop variable still counts: with
  # `item` unbound, `item.backup is defined` is false, so the task
  # SKIPS rather than failing. A sibling task with no when: at all, over
  # the same undefined source, still fails - that pairing is exactly
  # what buluma.mount recaps as `ok=4 failed=1 skipped=4` on both
  # engines.
  it "skips (not fails) when an item-referencing when: is false with item unbound" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated by item
            ansible.builtin.assert:
              that:
                - item.backup is boolean
            loop: "{{ undefined_var }}"
            when:
              - item.backup is defined
          - name: ungated over the same undefined source
            ansible.builtin.assert:
              that:
                - item.path is defined
            loop: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("skipping:")
    output.should contain("'undefined_var' is undefined")
    output.should contain("skipped=1")
    output.should contain("failed=1")
  end

  # A normally-resolving loop whose when: references the item must be
  # unaffected - the when: is still evaluated PER ITEM, not once against
  # an unbound item (which would wrongly skip the whole loop).
  it "still evaluates an item-referencing when: per item for a resolvable loop" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          rows:
            - {name: "keep", enabled: true}
            - {name: "drop", enabled: false}
        tasks:
          - name: per item
            ansible.builtin.debug:
              msg: "ran {{ item.name }}"
            loop: "{{ rows }}"
            when: item.enabled
      YAML

    status.success?.should be_true
    output.should contain("ran keep")
    output.should_not contain("ran drop")
  end

  # Scenario 11b - a DEFINED empty list still skips, it is not an error.
  it "skips a defined empty list" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          emptylist: []
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ emptylist }}"
      YAML

    status.success?.should be_true
    output.should contain("skipping:")
  end

  # Scenario 14 - ignore_errors: still suppresses it normally.
  it "is suppressed by ignore_errors: true" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ undefined_var }}"
            ignore_errors: true
          - name: after
            ansible.builtin.debug:
              msg: "AFTER-RAN"
      YAML

    status.success?.should be_true
    output.should contain("AFTER-RAN")
    output.should contain("ignored=1")
  end

  # Scenarios 12a/12b - include_tasks:/include_role: must fail BEFORE the
  # included content is entered. Real Ansible never reaches it; this
  # engine used to enter and start running it.
  it "fails include_tasks: without entering the included file" do
    inner = File.tempname("loop-strict-inner", ".yml")
    File.write(inner, <<-YAML)
      - name: inner
        ansible.builtin.debug:
          msg: "INNER-SHOULD-NOT-RUN"
      YAML

    begin
      status, output = run_playbook(<<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: inc
              ansible.builtin.include_tasks: #{inner}
              loop: "{{ undefined_var }}"
        YAML

      status.exit_code.should eq(2)
      output.should contain("'undefined_var' is undefined")
      output.should_not contain("INNER-SHOULD-NOT-RUN")
    ensure
      File.delete(inner) if File.exists?(inner)
    end
  end

  # Scenario 12c - include_vars: used to leak the engine's own
  # "undefined" sentinel through as a literal FILENAME
  # ("include_vars: file not found: undefined").
  it "fails include_vars: without trying to open a file named 'undefined'" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: inc
            ansible.builtin.include_vars: "{{ item }}"
            loop: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should_not contain("file not found: undefined")
  end

  # Scenario 10 - a handler's own undefined loop: source. This example
  # also guards the exit-code path: a failed handler must actually mark
  # the RUN as failed, not just print and recap failed=1 while exiting 0.
  it "fails a handler's undefined loop: source and marks the run failed" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: triggering
            changed_when: true
            notify: gated handler
        handlers:
          - name: gated handler
            ansible.builtin.debug:
              msg: "static text"
            loop: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should contain("failed=1")
  end
end
