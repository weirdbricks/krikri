require "../minitest_helper"

# Runs the compiled binary against a real playbook: the skipped-task no_log
# templating and its deprecation output are observable end-to-end only.
private REPRO_ROOT = File.expand_path("../..", __DIR__)
private REPRO_BIN  = File.join(REPRO_ROOT, "bin", "krikri-playbook")
private REPRO_INV  = File.join(REPRO_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")
private REPRO_DEPR = "[DEPRECATION WARNING]: The `bool` filter coerced invalid value '' (str) to False. This feature will be removed from ansible-core version 2.23."

# Real 2.19 templates a task's no_log: even when the when: skips it, and
# any core deprecation that templating raises still prints before the
# skipping line - krikri used to leave bare skips silent because it only
# resolved a templated no_log when a result or loop-item label needed it.
describe "skipped task's templated no_log deprecation" do
  it "emits the no_log templating deprecation before a task-level when false skip" do
    playbook = File.tempname("skipped-no-log-deprecation", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: skipped no_log
            debug:
              msg: hidden
            when: false
            no_log: "{{ '' | bool }}"
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(REPRO_BIN, ["-i", REPRO_INV, playbook], output: stdout, error: stderr)
    err = stderr.to_s

    err.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    err.must_include(REPRO_DEPR)
    stdout.to_s.must_include("skipping: [localhost]")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # The same gap hits the same task when the skip comes from an enclosing
  # block's when: false: real still templates the member's no_log: and
  # prints its deprecation under the member's own banner.
  it "emits the no_log templating deprecation before a block when false skip" do
    playbook = File.tempname("skipped-no-log-block-deprecation", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: skipped block
            block:
              - name: skipped no_log in block
                debug:
                  msg: hidden
                no_log: "{{ '' | bool }}"
            when: false
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(REPRO_BIN, ["-i", REPRO_INV, playbook], output: stdout, error: stderr)
    err = stderr.to_s

    err.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    err.must_include(REPRO_DEPR)
    stdout.to_s.must_include("skipping: [localhost]")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
