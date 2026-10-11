require "../minitest_helper"
require "file_utils"

# Ansible's `undef(hint=...)` Jinja global: a deliberately-failing value
# roles use as a required-var default (`cert_checker_email: "{{ undef(hint=
# 'You must specify an email to receive reports.') }}"`, deekayen
# .cert_checker, round 5460361). It RETURNS a strict undefined carrying the
# hint as its failure message - `| default(...)` catches it, `is defined` is
# false, and only a bare use fails, with the hint verbatim; the no-hint form
# fails with "Mandatory variable has not been overridden". All shapes
# live-verified against ansible-core 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("undef-hint", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def run_role_roleplay(defaults : String, extra_vars : String = "")
  dir = File.tempname("undef-hint-role", ".d")
  Dir.mkdir(dir)
  role = File.join(dir, "roles", "undefhint")
  FileUtils.mkdir_p(File.join(role, "defaults"))
  FileUtils.mkdir_p(File.join(role, "meta"))
  FileUtils.mkdir_p(File.join(role, "tasks"))
  File.write(File.join(role, "defaults", "main.yml"), defaults)
  File.write(File.join(role, "meta", "argument_specs.yml"), <<-YAML
    argument_specs:
      main:
        short_description: spec
        options:
          hint_opt:
            type: str
            required: true
    YAML
  )
  File.write(File.join(role, "tasks", "main.yml"), "---\n- name: past validation\n  ansible.builtin.debug:\n    msg: \"PAST-VALIDATION\"\n")
  playbook = File.join(dir, "play.yml")
  File.write(playbook, <<-YAML
    - hosts: localhost
      connection: local
      gather_facts: false
      #{extra_vars}
      roles:
        - role: undefhint
    YAML
  )
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "undef() Jinja global hint-bearing failure" do
  it "is caught by default(), rendering the fallback" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: default catches undef
            ansible.builtin.debug:
              msg: "{{ undef(hint='H1') | default('fallback') }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("\"msg\": \"fallback\"")
  end

  it "is not defined" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: is defined on undef
            ansible.builtin.debug:
              msg: "{{ undef(hint='H2') is defined }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("\"msg\": false")
  end

  it "fails a consumed arg with the hint verbatim" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: bare undef in msg
            ansible.builtin.debug:
              msg: "{{ undef(hint='H3') }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Error while resolving value for 'msg': H3")
  end

  it "fails with the no-hint wording when called bare" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: bare undef no hint
            ansible.builtin.debug:
              msg: "{{ undef() }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Error while resolving value for 'msg': Mandatory variable has not been overridden")
  end

  it "fails an assert's fail_msg finalization with the hint whether that: passes or fails" do
    # Real finalizes fail_msg EAGERLY (before that: is evaluated), so even
    # a passing assert fails the same way - live-verified vs 2.19.11.
    ["1 == 2", "1 == 1"].each do |condition|
      status, output = run_playbook(<<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          vars:
            hint_var: "{{ undef(hint='You must specify an email to receive reports.') }}"
          tasks:
            - name: assert with hint fail_msg
              ansible.builtin.assert:
                that:
                  - #{condition}
                fail_msg: "got: {{ hint_var }}"
                quiet: true
      YAML

      status.exit_code.must_equal(2)
      output.must_include("Finalization of task args for 'ansible.builtin.assert' failed: Error while resolving value for 'fail_msg': You must specify an email to receive reports.")
      output.must_include("failed=1")
    end
  end

  it "still fails assert finalization on a plain undefined fail_msg reference" do
    # The plain-undefined shape must keep its own wording (and the eager
    # finalization: even a PASSING assert fails) - live-verified vs 2.19.11.
    ["1 == 2", "1 == 1"].each do |condition|
      status, output = run_playbook(<<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: assert with plain undefined fail_msg
              ansible.builtin.assert:
                that:
                  - #{condition}
                fail_msg: "got: {{ not_defined_anywhere }}"
                quiet: true
      YAML

      status.exit_code.must_equal(2)
      output.must_include("Error while resolving value for 'fail_msg': 'not_defined_anywhere' is undefined")
      output.must_include("failed=1")
    end
  end

  it "fails validate_argument_spec with the role's own hint when a required default is undef" do
    status, output = run_role_roleplay(<<-YAML)
      # Comma-delimited list of email addresses
      hint_opt: "{{ undef(hint='You must specify an email to receive reports.') }}"
    YAML

    status.exit_code.must_equal(2)
    output.must_include("Task failed: You must specify an email to receive reports.")
    output.must_include("Origin: <unknown>")
    output.must_include("You must specify an email to receive reports.\nOrigin:")
    output.wont_include("PAST-VALIDATION")
    output.must_include("failed=1")
    output.wont_include("Finalization of task args for 'ansible.builtin.validate_argument_spec'")
  end

  it "passes validate_argument_spec when the option is provided" do
    defaults = <<-YAML
      # Comma-delimited list of email addresses
      hint_opt: "{{ undef(hint='You must specify an email to receive reports.') }}"
    YAML
    play_vars = "vars:\n        hint_opt: provided@example.com\n"
    status, output = run_role_roleplay(defaults, play_vars)

    status.success?.must_equal(true)
    output.must_include("PAST-VALIDATION")
    output.must_include("failed=0")
  end
end
