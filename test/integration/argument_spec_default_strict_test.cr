require "../minitest_helper"
require "file_utils"

# A role's meta/argument_specs.yml is templated STRICTLY by Ansible -
# `default:` expressions included, before the option's own presence is ever
# considered (live-verified against ansible-core 2.19.4, 2026-09-06,
# lablabs.rke2 investigation: `default: "{{ groups[rke2_servers_group_name] }}"`
# with no such group in the inventory fails validate_argument_spec with
# "object of type 'dict' has no attribute 'masters'" even when the option is
# passed explicitly). This engine used to resolve such defaults leniently to
# the "undefined" sentinel, pass the task, and only fail several tasks later
# when the same expression surfaced in a `when:`.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_role_roleplay(argument_specs : String, extra_vars : String = "")
  dir = File.tempname("argspec-default", ".d")
  Dir.mkdir(dir)
  role = File.join(dir, "roles", "specargs")
  FileUtils.mkdir_p(File.join(role, "meta"))
  FileUtils.mkdir_p(File.join(role, "tasks"))
  File.write(File.join(role, "meta", "argument_specs.yml"), argument_specs)
  File.write(File.join(role, "tasks", "main.yml"), "---\n- name: past validation\n  ansible.builtin.debug:\n    msg: \"PAST-VALIDATION\"\n")
  playbook = File.join(dir, "play.yml")
  File.write(playbook, <<-YAML
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        group_name: masters
      #{extra_vars}
      roles:
        - role: specargs
    YAML
  )
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "argument_specs.yml default: expressions are strictly templated" do
  it "fails validate_argument_spec on a dict-miss default, even with the option provided" do
    status, output = run_role_roleplay(<<-YAML)
      argument_specs:
        main:
          short_description: spec
          options:
            my_opt:
              type: str
              default: "{{ groups[group_name] }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("object of type 'dict' has no attribute 'masters'")
    output.must_include("failed=1")
    output.wont_include("PAST-VALIDATION")
  end

  it "fails validate_argument_spec on a default referencing an undefined variable" do
    status, output = run_role_roleplay(<<-YAML)
      argument_specs:
        main:
          short_description: spec
          options:
            my_opt:
              type: str
              default: "{{ totally_undefined_var }}"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("'totally_undefined_var' is undefined")
    output.must_include("failed=1")
  end

  it "passes with a literal default and applies it for type validation" do
    status, output = run_role_roleplay(<<-YAML)
      argument_specs:
        main:
          short_description: spec
          options:
            my_opt:
              type: int
              default: 7
      YAML

    status.success?.must_equal(true)
    output.must_include("PAST-VALIDATION")
    output.must_include("failed=0")
  end

  it "passes when a templated default resolves against play vars" do
    status, output = run_role_roleplay(<<-YAML)
      argument_specs:
        main:
          short_description: spec
          options:
            my_opt:
              type: str
              default: "{{ group_name }}-suffix"
      YAML

    status.success?.must_equal(true)
    output.must_include("PAST-VALIDATION")
  end
end
