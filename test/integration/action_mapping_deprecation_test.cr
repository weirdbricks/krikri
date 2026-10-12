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
    err.must_include("Use a string value for `action`.")
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
end
