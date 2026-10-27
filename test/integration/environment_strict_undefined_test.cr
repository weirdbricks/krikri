require "file_utils"
require "../minitest_helper"

# Runs the compiled binary against a real playbook - the environment:
# keyword's strict-undefined behavior lives in TaskExecutor#substitute_
# task_environment (private, called from the "finalization of task args"
# block), so only a full run can prove both the failure and the success
# shapes end to end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "environment: keyword strict-undefined" do
  # ryandaniels.server_update_reboot (round 300094): its apt/yum tasks set
  # `environment: "{{ proxy_env }}"` with proxy_env defined NOWHERE in the
  # role (it comes from the caller's inventory/vars). ansible-playbook
  # fails each such task with "Error processing keyword 'environment':
  # 'proxy_env' is undefined"; krikri's parser silently dropped the
  # non-hash form and the executor substituted the (never-parsed) values
  # leniently, so the tasks ran with no env at all.
  it "fails the task when the referenced variable is undefined" do
    playbook = File.tempname("environment-strict-undefined", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: apt-like task with undefined proxy_env
            ansible.builtin.command: /bin/true
            environment: "{{ proxy_env }}"
          - name: after
            ansible.builtin.debug:
              msg: still running
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    output.to_s.must_include("'proxy_env' is undefined")
    output.to_s.must_include("Error processing keyword 'environment'")
    output.to_s.must_include("failed=1")
  end

  it "fails the task for an undefined value inside a dict-form environment" do
    playbook = File.tempname("environment-dict-strict-undefined", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: dict-form environment with undefined value
            ansible.builtin.command: /bin/true
            environment:
              MISSING_VAR: "{{ never_defined_anywhere }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    output.to_s.must_include("'never_defined_anywhere' is undefined")
    output.to_s.must_include("failed=1")
  end

  # ansible-core 2.19 prints ONE [ERROR] block for an undefined variable in
  # a string-form environment: the keyword chain ("Task failed." at the
  # name: key, "Error processing keyword 'environment'." with no Origin and
  # the raw value's python repr, then the bare "'proxy_env' is undefined"
  # at the value's first character) - not the "Finalization of task args"
  # chain a task-arg failure gets (live-captured, issue #625).
  it "prints the keyword chain block for a string-form environment with an undefined variable" do
    playbook = File.tempname("environment-string-chain", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: string-form environment with undefined variable
            ansible.builtin.command: /bin/true
            environment: "{{ proxy_env }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    output.to_s.must_include("Error processing keyword 'environment'.\nOrigin: <unknown>")
    output.to_s.must_include("['{{ proxy_env }}']")
    output.to_s.wont_include("Finalization of task args")
    output.to_s.must_include("\"msg\": \"Task failed: Error processing keyword 'environment': 'proxy_env' is undefined\"")
    # ansible-core leaves a blank line between the value's caret and the fatal: line
    output.to_s.must_match(/\^ column \d+\n\nfatal: /)
  end

  it "treats a bare environment: key with no value as no environment, not a crash" do
    # lifeofguenter.nginx round 5250092's "Configure" task has a bare
    # `environment:` with no value. ansible-playbook 2.19.11 treats a
    # null environment as "no environment" and runs the task; krikri
    # used to stringify the null into an empty environment_raw, which
    # env finalization JSON.parsed and crashed on ("unexpected token
    # '<EOF>' at line 1, column 1") before the task ever ran.
    playbook = File.tempname("environment-null-value", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          nginx_compile_modsecurity: ''
        tasks:
          - name: Configure
            ansible.builtin.command: >
              echo configured
              {{ nginx_compile_modsecurity }}
            args:
              chdir: /tmp
            environment:
            changed_when: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("failed=0")
    output.to_s.must_include("changed=1")
    output.to_s.wont_include("<EOF>")
  end

  it "still applies the env vars when the variable IS defined" do
    playbook = File.tempname("environment-defined", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          proxy_env:
            KRIKRI_ENV_PROBE: "hello-from-env"
        tasks:
          - name: shell reads the env var
            ansible.builtin.shell: echo "$KRIKRI_ENV_PROBE"
            environment: "{{ proxy_env }}"
            register: probe
          - name: show it
            ansible.builtin.debug:
              var: probe.stdout
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("hello-from-env")
  end

  it "treats a non-dict environment value (e.g. an empty list) as no environment, not a task failure" do
    # ryandaniels.connectivity_test (round 601446): a role default like
    # `proxy_env: []`, meant to be overridden by the caller with a real
    # dict but left as an empty list otherwise. Ansible warns
    # "could not parse environment value, skipping" and runs the task
    # with no extra env; krikri used to raise
    # "Error processing keyword 'environment': expected a dict, got []"
    # and fail the task outright.
    playbook = File.tempname("environment-non-dict-value", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          proxy_env: []
        tasks:
          - name: task with a non-dict environment value
            ansible.builtin.command: /bin/true
            environment: "{{ proxy_env }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("failed=0")
  end

  it "warns and runs the task when the environment value renders to a non-object JSON list" do
    # ansible-playbook 2.19.11 prints
    # "[WARNING]: could not parse environment value, skipping:
    # ['{{ proxy_env }}']" for `proxy_env: []` and still runs the task;
    # krikri used to fail it (round 601446) and later swallowed the
    # warning silently.
    playbook = File.tempname("environment-list-warning", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          proxy_env: []
        tasks:
          - name: task with a non-dict environment value
            ansible.builtin.command: /bin/true
            environment: "{{ proxy_env }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include(
      "[WARNING]: could not parse environment value, skipping: ['{{ proxy_env }}']"
    )
    output.to_s.must_include("failed=0")
  end

  it "warns and succeeds when the environment value is a literal non-JSON string" do
    # `environment: "foo bar"` renders to a string no JSON parser
    # accepts; ansible-playbook 2.19.11 warns `['foo bar']` and the
    # task succeeds. krikri used to raise "Unexpected char 'o'" out of
    # JSON.parse and fail the task.
    playbook = File.tempname("environment-non-json-string", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: task with a literal non-JSON environment
            ansible.builtin.command: /bin/true
            environment: "foo bar"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include(
      "[WARNING]: could not parse environment value, skipping: ['foo bar']"
    )
    output.to_s.must_include("failed=0")
  end

  it "skips the could-not-parse warning for a when-false task with an unparseable environment" do
    # Ansible finalizes the environment keyword only for tasks that
    # actually run: a `when:`-skipped task prints no warning even
    # though its environment value would fail to parse.
    playbook = File.tempname("environment-skipped-no-warning", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          proxy_env: []
        tasks:
          - name: skipped task with a non-dict environment value
            ansible.builtin.command: /bin/true
            environment: "{{ proxy_env }}"
            when: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.wont_include("could not parse environment value")
  end
end
