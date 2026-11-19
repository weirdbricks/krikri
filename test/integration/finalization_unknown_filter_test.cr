require "../minitest_helper"
require "file_utils"

# An unknown FILTER (or test) name inside a task arg is a template COMPILE
# error: ansible-core 2.19.11 routes it through the same "Finalization
# of task args" chain as an undefined variable ("... failed: Error while
# resolving value for 'msg': Syntax error in template: No filter named
# 'ljust'."), and the inner Origin stanza points at the failing param KEY's
# first character on the module line even for flow style (`- debug: msg=...`
# -> column 14). Live-compared byte for byte with ansible-playbook
# 2.19.11 via scripts/output_parity.sh.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (unknown filter)" do
  it "wraps an unknown-filter arg error in the finalization chain with the param's own origin" do
    playbook = File.tempname("finalization-unknown-filter", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.debug: msg="x{{ 'hi' | ljust(5) }}y"
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': Syntax error in template: No filter named 'ljust'.")
    text.must_include("Error while resolving value for 'msg': Syntax error in template: No filter named 'ljust'.\nOrigin: #{playbook}:4:30")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': Syntax error in template: No filter named 'ljust'.\"}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "chains an unknown-filter failure in the value's own variable definition to that definition" do
    playbook = File.tempname("finalization-unknown-filter-chain", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          broken_filter: "{{ 'x' | bogus_kpg_filter('a') }}"
        tasks:
          - name: var form
            ansible.builtin.debug:
              var: broken_filter
            ignore_errors: true
          - name: msg form
            ansible.builtin.debug:
              msg: '{{ broken_filter }}'
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Error while resolving `var` expression: Syntax error in template: No filter named 'bogus_kpg_filter'.")
    text.must_include("Error while resolving `var` expression.\nOrigin: #{playbook}:8:14")
    text.must_include("Error while resolving value for 'msg'.\nOrigin: #{playbook}:12:14")
    text.must_include("Syntax error in template: No filter named 'bogus_kpg_filter'.\nOrigin: #{playbook}:4:20")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Error while resolving `var` expression: Syntax error in template: No filter named 'bogus_kpg_filter'.\"}")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': Syntax error in template: No filter named 'bogus_kpg_filter'.\"}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "chains an unknown-test failure from a debug var: to the definition that uses it" do
    playbook = File.tempname("finalization-unknown-test-chain", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          broken_test: "{{ 'x' is bogus_kpg_test }}"
        tasks:
          - name: var form
            ansible.builtin.debug:
              var: broken_test
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Error while resolving `var` expression: Syntax error in template: No test named 'bogus_kpg_test'.")
    text.must_include("Error while resolving `var` expression.\nOrigin: #{playbook}:8:14")
    text.must_include("Syntax error in template: No test named 'bogus_kpg_test'.\nOrigin: #{playbook}:4:18")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails an unknown filter in an and arm the short-circuit never reaches" do
    playbook = File.tempname("finalization-unknown-filter-dead-arm", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          distro: Debian
          distro_version: "10"
        tasks:
          - ansible.builtin.set_fact:
              legacy: "{{ (distro == 'Ubuntu' and distro_version | bogus_kpg_filter('8', '<')) }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(false)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'legacy': Syntax error in template: No filter named 'bogus_kpg_filter'.")
    text.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'legacy': Syntax error in template: No filter named 'bogus_kpg_filter'.\"}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails an unknown test in an and arm the short-circuit never reaches" do
    playbook = File.tempname("finalization-unknown-test-dead-arm", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          distro: Debian
        tasks:
          - ansible.builtin.set_fact:
              legacy: "{{ distro == 'Ubuntu' and distro is bogus_kpg_test }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(false)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'legacy': Syntax error in template: No test named 'bogus_kpg_test'.")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Jinja's compiler resolves filter/test names under a soft frame, and an
  # inline conditional expression pushes one for its condition and both
  # arms - so a name there stays a RUNTIME failure and only fails the task
  # when the selected arm actually renders (live-verified vs 2.21.6).
  it "passes an unknown filter in an inline conditional expression arm that never renders" do
    playbook = File.tempname("finalization-unknown-filter-dead-ternary", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.set_fact:
              legacy: "{{ 'a' | bogus_kpg_filter if false else 'b' }}"
          - ansible.builtin.debug:
              var: legacy
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(true)
    text.wont_include("No filter named")
    text.must_include("\"legacy\": \"b\"")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
