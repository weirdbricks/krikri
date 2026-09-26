require "file_utils"
require "../spec_helper"

# meta/argument_specs.yml required-ness: real ansible-core applies spec
# defaults with set_default=False before check_required_arguments
# (module_utils/common/parameters.py _set_defaults), so only a default
# whose value is not None stands in for a missing option - `default: null`
# alongside `required: true` still fails. Found via round 979000
# (robertdebock.vault_agent): its vault_agent_address is `required: true,
# default: null`, real ansible-playbook failed the synthesized "Validating
# arguments against arg spec 'main'" task immediately with
# {"argument_errors": ["missing required arguments: vault_agent_address"]},
# while this engine treated the null default as a provided value, passed
# validation, and only failed the role's own assert-fallback tasks later
# with a generic assertion error instead. All shapes below live-verified
# against ansible-core 2.19.4 (/tmp minimal repro, 2026-09-26).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_role_roleplay(argument_specs : String, play_vars : String = "")
  dir = File.tempname("argspec-required", ".d")
  Dir.mkdir(dir)
  role = File.join(dir, "roles", "specargs")
  FileUtils.mkdir_p(File.join(role, "meta"))
  FileUtils.mkdir_p(File.join(role, "tasks"))
  File.write(File.join(role, "meta", "argument_specs.yml"), argument_specs)
  File.write(File.join(role, "tasks", "main.yml"), "---\n- name: past validation\n  ansible.builtin.debug:\n    msg: \"PAST-VALIDATION\"\n")
  playbook = File.join(dir, "play.yml")
  vars_block = play_vars.empty? ? "" : play_vars.lines.map { |line| "  #{line}" }.join("\n") + "\n"
  File.write(playbook, "- hosts: localhost\n  connection: local\n  gather_facts: false\n#{vars_block}  roles:\n    - role: specargs\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "meta/argument_specs.yml required-ness" do
  it "fails on a required option with no value and no default" do
    status, output = run_role_roleplay(<<-YAML)
      argument_specs:
        main:
          short_description: spec
          options:
            req_opt:
              required: true
              type: str
      YAML

    status.exit_code.should eq(2)
    output.should contain("missing required arguments: req_opt")
    output.should contain("argument_errors")
    output.should contain("Validation of arguments failed:")
    output.should_not contain("PAST-VALIDATION")
  end

  it "fails on a required option whose default is null (round 979000 regression)" do
    status, output = run_role_roleplay(<<-YAML)
      argument_specs:
        main:
          short_description: spec
          options:
            vault_agent_address:
              required: true
              default: null
              type: str
      YAML

    status.exit_code.should eq(2)
    output.should contain("missing required arguments: vault_agent_address")
    output.should_not contain("PAST-VALIDATION")
  end

  it "combines every missing required option into one sorted message" do
    status, output = run_role_roleplay(<<-YAML)
      argument_specs:
        main:
          short_description: spec
          options:
            zeta:
              required: true
              type: str
            alpha:
              required: true
              type: str
            provided_opt:
              required: false
              default: "x"
              type: str
      YAML

    status.exit_code.should eq(2)
    output.should contain("missing required arguments: alpha, zeta")
    output.should_not contain("missing required argument:")
  end

  it "passes when the required option is provided" do
    play_vars = <<-VARS
      vars:
        req_opt: "http://vault.example.com:8200"
      VARS
    status, output = run_role_roleplay(<<-YAML, play_vars)
      argument_specs:
        main:
          short_description: spec
          options:
            req_opt:
              required: true
              default: null
              type: str
      YAML

    status.success?.should be_true
    output.should contain("PAST-VALIDATION")
    output.should contain("failed=0")
  end

  it "passes when the required option is provided as an explicit null" do
    play_vars = <<-VARS
      vars:
        req_opt: null
      VARS
    status, output = run_role_roleplay(<<-YAML, play_vars)
      argument_specs:
        main:
          short_description: spec
          options:
            req_opt:
              required: true
              default: null
              type: str
      YAML

    status.success?.should be_true
    output.should contain("PAST-VALIDATION")
  end

  it "keeps working when the role has no meta/argument_specs.yml" do
    dir = File.tempname("argspec-required", ".d")
    begin
      Dir.mkdir(dir)
      role = File.join(dir, "roles", "nospec")
      FileUtils.mkdir_p(File.join(role, "tasks"))
      File.write(File.join(role, "tasks", "main.yml"), "---\n- name: only task\n  ansible.builtin.debug:\n    msg: \"PAST-VALIDATION\"\n")
      playbook = File.join(dir, "play.yml")
      File.write(playbook, "---\n- hosts: localhost\n  connection: local\n  gather_facts: false\n  roles:\n    - role: nospec\n")
      output = IO::Memory.new
      status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

      status.success?.should be_true
      output.to_s.should contain("PAST-VALIDATION")
      output.to_s.should_not contain("Validating arguments")
    ensure
      FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
    end
  end
end
