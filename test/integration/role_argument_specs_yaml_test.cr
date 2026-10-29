require "../minitest_helper"
require "file_utils"

# Ansible accepts .yml/.yaml/.json for meta/argument_specs (same
# extension list as its main-file lookups), .yml first: a role shipping
# only meta/argument_specs.yaml (stephdewit.sshca does exactly that,
# issue #638) still gets "Validating arguments against arg spec 'main'"
# auto-inserted as its first task, and validation failures against it
# report origins naming the .yaml file.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private ARGUMENT_SPECS_YAML = <<-YAML
  argument_specs:
    main:
      short_description: Manage SSH CA
      options:
        sshca_key:
          type: str
          required: true
  YAML

private def run_playbook(files : Hash(String, String)) : {Process::Status, String}
  nonce = Random::Secure.hex(4)
  dir = PluginSpecHelper.tmp_path("argspec-yaml-#{nonce}")
  files.each do |path, content|
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, File.join(dir, "play.yml")], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

private def role_files : Hash(String, String)
  {
    "roles/r1/meta/argument_specs.yaml" => ARGUMENT_SPECS_YAML,
    "roles/r1/tasks/main.yml"           => "---\n- name: role task\n  ansible.builtin.debug:\n    msg: hi\n",
    "play.yml"                          => "- hosts: all\n  gather_facts: false\n  roles:\n    - r1\n",
  }
end

describe "role argument_specs.yaml" do
  it "synthesizes the validation task first and stops on a missing required option" do
    status, output = run_playbook(role_files)

    status.exit_code.must_equal(2)
    output.must_include("TASK [r1 : Validating arguments against arg spec 'main' - Manage SSH CA]")
    output.must_include("missing required arguments: sshca_key")
    output.wont_include("msg\": \"hi")
  end

  it "runs the role's own tasks when the required option is provided" do
    files = role_files
    files["play.yml"] = "- hosts: all\n  gather_facts: false\n  vars:\n    sshca_key: ssh-ed25519 AAAA\n  roles:\n    - r1\n"
    status, output = run_playbook(files)

    status.exit_code.must_equal(0)
    output.must_include("Validating arguments against arg spec 'main'")
    output.must_include("msg\": \"hi")
    output.must_include("ok=2")
    validate_line = output.lines.index { |line| line.includes?("Validating arguments against arg spec 'main'") }
    role_task_line = output.lines.index { |line| line.includes?("TASK [r1 : role task]") }
    (validate_line && role_task_line && validate_line < role_task_line).must_equal(true)
  end

  it "prefers argument_specs.yml over argument_specs.yaml when both exist" do
    files = role_files
    files["roles/r1/meta/argument_specs.yml"] = "argument_specs:\n  main:\n    options:\n      other:\n        type: str\n        required: true\n"
    _, output = run_playbook(files)

    output.must_include("missing required arguments: other")
    output.wont_include("missing required arguments: sshca_key")
  end

  it "ignores the meta main file's argument_specs when argument_specs.yaml exists" do
    files = role_files
    files["roles/r1/meta/main.yml"] = "argument_specs:\n  main:\n    options:\n      from_main:\n        type: str\n        required: true\n"
    _, output = run_playbook(files)

    output.must_include("missing required arguments: sshca_key")
    output.wont_include("missing required arguments: from_main")
  end

  it "skips the validation task when the role's when is false" do
    # Real ansible tags the auto-inserted "Validating arguments" task with
    # the role's (or dependency's) `when:`, so a false condition skips it -
    # `skipping: [host]`, recap skipped=1 - and never validates, so even a
    # missing required option can't fail the play (issue #479).
    files = role_files
    files["play.yml"] = "- hosts: all\n  gather_facts: false\n  roles:\n    - role: r1\n      when: false\n"
    status, output = run_playbook(files)

    status.exit_code.must_equal(0)
    output.must_include("TASK [r1 : Validating arguments against arg spec 'main' - Manage SSH CA]")
    output.must_include("skipping: [localhost]")
    output.wont_include("ok: [localhost]")
    output.must_include("skipped=2")
    output.wont_include("missing required arguments")
  end

  it "names the argument_specs.yaml file in a spec-default origin line" do
    files = role_files
    files["roles/r1/meta/argument_specs.yaml"] = <<-YAML
      argument_specs:
        main:
          short_description: Manage SSH CA
          options:
            sshca_key:
              type: str
              default: "{{ undefined_var }}"
      YAML
    files["play.yml"] = "- hosts: all\n  gather_facts: false\n  vars:\n    sshca_key: provided\n  roles:\n    - r1\n"
    _, output = run_playbook(files)

    output.must_include("argument_specs.yaml")
  end
end
