require "../minitest_helper"

# Runs the compiled binary against a real playbook: the deprecation hint
# and the mapping-form `action:` warning are parse-time stderr output,
# only observable end-to-end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Real 2.19.11 resolves a mapping-form legacy `action:`'s module LAZILY,
# at run time - so a `when: false` task with an unknown module name still
# loads, printing the mapping deprecation (Origin at the mapping's first
# key) at load, and only a later REACHABLE unresolvable task aborts.
describe "mapping-form action deprecation and lazy module resolution" do
  it "warns at load for the mapping action and refuses only the later bare ec2 task" do
    playbook = File.tempname("action-mapping-deprecation", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: legacy mapping action
            action:
              module: some_unknown_module_xyz
              region: x
            when: false
          - name: bare ec2
            ec2:
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    err = stderr.to_s

    err.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    err.must_include("[DEPRECATION WARNING]: Using a mapping for `action` is deprecated. This feature will be removed from ansible-core version 2.23.")
    err.must_match(/\^ column \d+\n\nUse a string value for `action`\./)
    err.must_include("Origin: #{File.expand_path(playbook)}:7:9")
    err.must_include("couldn't resolve module/action 'ec2'")
    # The Origin context block legitimately echoes the `module:` source
    # line; the refusal itself must never name the mapping's module.
    err.wont_include("couldn't resolve module/action 'some_unknown_module_xyz'")
    # The bare ec2 refusal is a playbook-load abort (real: rc=4, no task
    # output), so stdout never reaches a PLAY RECAP.
    stdout.to_s.wont_include("PLAY RECAP")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Real 2.19.11 prints the SAME mapping-form deprecation for a mapping
  # `local_action:` as for a mapping `action:` - same wording, Origin at
  # the mapping's first key - while krikri used to stay silent because
  # only the lazy-resolution flag was gated on the directive.
  it "warns at load for a mapping-form local_action with its own Origin key" do
    playbook = File.tempname("local-action-mapping-deprecation", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: mapping local_action
            local_action:
              module: command
              cmd: echo hi
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    err = stderr.to_s

    err.must_include("[DEPRECATION WARNING]: Using a mapping for `action` is deprecated. This feature will be removed from ansible-core version 2.23.")
    # Same convention as the `action:` test above: the Origin is the
    # mapping's first key (`module:`), not the `local_action:` line.
    err.must_include("Origin: #{File.expand_path(playbook)}:7:9")
    err.must_match(/\^ column \d+\n\nUse a string value for `action`\./)
    # The warning must not break the task itself: the local_action still
    # runs and the run reaches a PLAY RECAP.
    stdout.to_s.must_include("PLAY RECAP")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Issue #666 (xlab_si.nuage_create_entity): a mapping `local_action:`
  # is lazy like a mapping `action:` - a when:-false task with an
  # unresolvable module name loads fine and skips (rc=0), where krikri
  # used to refuse the whole playbook at load (rc=4, zero tasks).
  it "loads a mapping local_action behind when: false and only skips it" do
    playbook = File.tempname("local-action-mapping-when-false", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: mapping local_action behind when false
            local_action:
              module: some_unknown_module_xyz
              auth: x
            when: false
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    out = stdout.to_s

    status.exit_code.must_equal(0)
    out.must_include("skipping: [localhost]")
    out.must_include("PLAY RECAP")
    # Never reached, so never failed: no Cannot-resolve failure anywhere.
    out.wont_include("Cannot resolve 'some_unknown_module_xyz'")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # The reached shape: ansible 2.19.11 fails the REACHED task (rc=2) with
  # the two-segment "Cannot resolve '...' to an action or module." chain
  # (task-level Origin at the task's name line, cause's at the mapping's
  # own `module:` VALUE token) and the fatal line - NOT the exit-4
  # unported-module accounting the lazy flow used to give.
  it "fails a reached mapping local_action with the Cannot resolve chain (rc 2)" do
    playbook = File.tempname("local-action-mapping-reachable", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: mapping local_action reachable
            local_action:
              module: some_unknown_module_xyz
              auth: x
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    out = stdout.to_s

    status.exit_code.must_equal(2)
    # The [ERROR] chain rides stdout (the same channel every other task-
    # failure chain in this engine uses), unlike the load-time
    # deprecation warning above which is stderr.
    out.must_include("[ERROR]: Task failed: Cannot resolve 'some_unknown_module_xyz' to an action or module.")
    out.must_include("<<< caused by >>>")
    out.must_include("Cannot resolve 'some_unknown_module_xyz' to an action or module.")
    # The cause stanza's Origin is the `module:` VALUE token itself
    # (column 17: 8 spaces + "module: "), like real's 6:17 on the repro.
    out.must_include("Origin: #{File.expand_path(playbook)}:7:17")
    # Host == delegate here (localhost -> localhost), so no "-> localhost"
    # label - real 2.19.11 prints the bare host in that case (live-verified
    # with the issue #666 repro under a localhost inventory; a host OTHER
    # than the delegate gets `fatal: [host -> localhost]`).
    out.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Cannot resolve 'some_unknown_module_xyz' to an action or module.\"}")
    out.must_include("failed=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # ansible 2.19.11 resolves the module BEFORE templating the task args:
  # with an undefined variable in a reached mapping local_action's args,
  # the failure is the Cannot-resolve chain, never a Finalization-of-args
  # failure (the undefined variable never surfaces).
  it "fails a reached mapping local_action with undefined args on the Cannot resolve chain, not Finalization (rc 2)" do
    playbook = File.tempname("local-action-mapping-undefined-args", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: mapping local_action undefined args
            local_action:
              module: some_unknown_module_xyz
              auth: '{{ nuage_auth_undefined }}'
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    out = stdout.to_s

    status.exit_code.must_equal(2)
    out.must_include("[ERROR]: Task failed: Cannot resolve 'some_unknown_module_xyz' to an action or module.")
    out.wont_include("Finalization of task args")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
