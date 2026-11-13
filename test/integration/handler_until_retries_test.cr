require "../minitest_helper"
require "file_utils"

# A handler with until:/retries:/delay: retries like a regular task
# (issue #620): real prints the FAILED - RETRYING callback lines under
# the handler's own RUNNING HANDLER banner and stamps the final
# registered result with the attempts key - a notified handler that
# fails through every attempt is fatal after exactly 1 + retries runs.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "handler until/retries" do
  it "retries a failing handler with FAILED - RETRYING lines and an attempts key" do
    tempdir = File.tempname("handler-until-retries").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger the handler
            ansible.builtin.command:
              cmd: /bin/true
            changed_when: true
            notify: Run flaky installer
        handlers:
          - name: Run flaky installer
            ansible.builtin.command:
              cmd: /bin/false
            changed_when: true
            register: result
            until:
              - result is not failed
            retries: 2
            delay: 1
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # One FAILED - RETRYING line per failed attempt that still has
    # retries left, then the fatal - matching real's handler output for
    # the same playbook. 2.21 counts the retries REMAINING AFTER each
    # line (retries: 2 prints 1 then 0), where 2.19 printed 2 then 1.
    text.must_include("FAILED - RETRYING: [localhost]: Run flaky installer (1 retries left).")
    text.must_include("FAILED - RETRYING: [localhost]: Run flaky installer (0 retries left).")
    text.wont_include("(-1 retries left)")
    text.must_include("\"attempts\": 2")
    status.exit_code.must_equal(2)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "stops retrying a handler that passes on its second attempt" do
    tempdir = File.tempname("handler-until-pass").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    marker = File.join(tempdir, "marker")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger the handler
            ansible.builtin.command:
              cmd: /bin/true
            changed_when: true
            notify: Run flaky installer
        handlers:
          - name: Run flaky installer
            ansible.builtin.shell: |
              if [ -f #{marker} ]; then exit 0; fi
              touch #{marker}
              exit 1
            changed_when: true
            register: result
            until: result is not failed
            retries: 2
            delay: 1

      - hosts: localhost
        gather_facts: false
        tasks:
          - name: show attempts
            ansible.builtin.debug:
              msg: "attempts={{ result.attempts }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # The marker file makes attempt 2 pass, so exactly one retry line
    # prints and the handler ends ok with attempts: 2 - no fatal.
    text.must_include("FAILED - RETRYING: [localhost]: Run flaky installer (1 retries left).")
    text.wont_include("(0 retries left)")
    text.wont_include("FAILED!")
    # The registered handler result carries the successful attempt's
    # 1-based number - observed through the follow-up play's debug.
    text.must_include("attempts=2")
    status.exit_code.must_equal(0)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "renders templated retries and delay values per task" do
    tempdir = File.tempname("handler-templated-retries").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          retries_n: 4
        tasks:
          - name: trigger the handler
            ansible.builtin.command:
              cmd: /bin/true
            changed_when: true
            notify: Run flaky installer
        handlers:
          - name: Run flaky installer
            ansible.builtin.command:
              cmd: /bin/false
            changed_when: true
            register: result
            until:
              - result is not failed
            retries: "{{ retries_n }}"
            delay: "{{ 0 }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # Real templates retries:/delay: per task before the attempt loop, so
    # the templated 4 gives exactly four RETRYING lines (2.21 counts 3..0
    # left) and the fatal result carries attempts: 4 (the retries count is
    # stamped on a never-passing until, not 1 + retries) - the pre-fix
    # behavior silently fell back to the implicit 3 retries.
    text.must_include("FAILED - RETRYING: [localhost]: Run flaky installer (3 retries left).")
    text.must_include("FAILED - RETRYING: [localhost]: Run flaky installer (0 retries left).")
    text.wont_include("(-1 retries left)")
    text.must_include("\"attempts\": 4")
    status.exit_code.must_equal(2)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "retries a failing handler in check mode with FAILED - RETRYING lines and an attempts key" do
    tempdir = File.tempname("handler-until-check").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger the handler
            ansible.builtin.file:
              path: #{File.join(tempdir, "touched")}
              state: touch
            changed_when: true
            notify: Run flaky installer
        handlers:
          - name: Run flaky installer
            ansible.builtin.fail:
              msg: boom
            register: result
            until:
              - result is not failed
            retries: 2
            delay: 0
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "--check", playbook], output: output, error: output)
    text = output.to_s

    # Real's handler attempt loop runs under --check too (issue #1175,
    # live-verified vs 2.21.6): the same per-attempt RETRYING lines
    # under the RUNNING HANDLER banner and a fatal carrying attempts -
    # the pre-fix check-mode guard skipped the handler's retries as
    # well as a regular task's.
    text.must_include("FAILED - RETRYING: [localhost]: Run flaky installer (1 retries left).")
    text.must_include("FAILED - RETRYING: [localhost]: Run flaky installer (0 retries left).")
    text.must_include(%(fatal: [localhost]: FAILED! => {"attempts": 2, "changed": false, "msg": "boom"}))
    status.exit_code.must_equal(2)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
