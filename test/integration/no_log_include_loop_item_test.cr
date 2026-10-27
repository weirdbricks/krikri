require "../minitest_helper"

# Regression spec for issue #613: a looped include_tasks whose no_log
# resolves true must censor the loop item on ansible's per-iteration
# lines - `included: <path> for localhost => (item=(censored due to
# no_log))` and the matching skipping: line - never print the raw item,
# which can itself be the secret. Real ansible-playbook (2.19) censors
# these lines; previously krikri printed the item verbatim.
#
# Drives the compiled binary (the display layer is puts-based), same
# harness style as no_log_delegate_display_test.cr.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_include_playbook(yaml : String)
  include_file = File.tempname("no-log-include-loop", ".yml")
  File.write(include_file, "- debug:\n    msg: included ok\n")
  playbook = File.tempname("no-log-include-loop", ".yml")
  File.write(playbook, yaml.gsub("{{ INCLUDE_PATH }}", include_file))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(include_file) if include_file && File.exists?(include_file)
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "no_log censoring on looped include item labels" do
  it "censors the loop item on an included line for a no_log include_tasks" do
    _status, output = run_include_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          secret_flag: true
        tasks:
          - name: secret include
            include_tasks: "{{ INCLUDE_PATH }}"
            no_log: "{{ secret_flag | default(false) }}"
            loop:
              - very-secret-item
      YAML

    output.must_include("(item=(censored due to no_log))")
    output.wont_include("very-secret-item")
  end

  it "censors the loop item on the skipping line for a no_log include_tasks" do
    _status, output = run_include_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          secret_flag: true
        tasks:
          - name: secret include skip
            include_tasks: "{{ INCLUDE_PATH }}"
            no_log: "{{ secret_flag | default(false) }}"
            when: false
            loop:
              - very-secret-item
      YAML

    output.must_include("skipping: [localhost] => (item=(censored due to no_log))")
    output.wont_include("very-secret-item")
  end

  it "prints the raw loop item when no_log is a literal false" do
    _status, output = run_include_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: plain include
            include_tasks: "{{ INCLUDE_PATH }}"
            no_log: false
            loop:
              - plain-item
      YAML

    output.must_include("(item=plain-item)")
  end

  it "censors the loop item on an included line for a templated no_log that resolves false" do
    _status, output = run_include_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          secret_flag: false
        tasks:
          - name: templated-false include
            include_tasks: "{{ INCLUDE_PATH }}"
            no_log: "{{ secret_flag | default(false) }}"
            loop:
              - templated-false-item
      YAML

    output.must_include("(item=(censored due to no_log))")
    output.wont_include("templated-false-item")
  end

  it "prints the raw loop item on a skipping line for a templated no_log that resolves false" do
    _status, output = run_include_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          secret_flag: false
        tasks:
          - name: templated-false include skip
            include_tasks: "{{ INCLUDE_PATH }}"
            no_log: "{{ secret_flag | default(false) }}"
            when: false
            loop:
              - skip-plain-item
      YAML

    output.must_include("(item=skip-plain-item)")
    output.wont_include("censored due to no_log")
  end
end
