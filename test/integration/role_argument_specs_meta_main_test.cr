require "../minitest_helper"
require "file_utils"

# Argument specs read from the role's meta main file (meta/main.yml or
# meta/main.yaml), not just meta/argument_specs.yml: e.g. pimvh.cloud_init
# ships only meta/main.yaml with argument_specs.main, and ansible still
# auto-inserts "Validating arguments against arg spec 'main' - ..." as the
# role's first task (issue #602, root cause live-verified against
# ansible-playbook). argument_specs.yml keeps precedence when both exist.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private META_MAIN_SPEC = <<-YAML
  argument_specs:
    main:
      short_description: Install cloud-init config
      options:
        fqdn:
          type: str
          required: true
  YAML

private def run_playbook(files : Hash(String, String)) : {Process::Status, String}
  nonce = Random::Secure.hex(4)
  dir = PluginSpecHelper.tmp_path("argspec-meta-main-#{nonce}")
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

private def role_files(meta_file : String) : Hash(String, String)
  {
    "roles/r1/#{meta_file}"   => META_MAIN_SPEC,
    "roles/r1/tasks/main.yml" => "---\n- name: role task\n  ansible.builtin.debug:\n    msg: hi\n",
    "play.yml"                => "- hosts: all\n  gather_facts: false\n  roles:\n    - r1\n",
  }
end

describe "role argument_specs from the meta main file" do
  it "synthesizes the validation task from meta/main.yml and stops on a missing required option" do
    status, output = run_playbook(role_files("meta/main.yml"))

    status.exit_code.must_equal(2)
    output.must_include("TASK [r1 : Validating arguments against arg spec 'main' - Install cloud-init config]")
    output.must_include("missing required arguments: fqdn")
    output.wont_include("msg\": \"hi")
  end

  it "reads meta/main.yaml the same way" do
    status, output = run_playbook(role_files("meta/main.yaml"))

    status.exit_code.must_equal(2)
    output.must_include("Validating arguments against arg spec 'main'")
    output.wont_include("msg\": \"hi")
  end

  it "runs the role's own tasks when the required option is provided" do
    files = role_files("meta/main.yml")
    files["play.yml"] = "- hosts: all\n  gather_facts: false\n  vars:\n    fqdn: host.example.com\n  roles:\n    - r1\n"
    status, output = run_playbook(files)

    status.exit_code.must_equal(0)
    output.must_include("Validating arguments against arg spec 'main'")
    output.must_include("msg\": \"hi")
    output.must_include("failed=0")
  end

  it "prefers meta/argument_specs.yml when both files exist" do
    files = role_files("meta/main.yml")
    files["roles/r1/meta/argument_specs.yml"] = "argument_specs:\n  main:\n    options:\n      other:\n        type: str\n        required: true\n"
    _, output = run_playbook(files)

    output.must_include("missing required arguments: other")
    output.wont_include("missing required arguments: fqdn")
  end

  it "reports a dict option's own required keys as a sub-spec, found in the option" do
    files = role_files("meta/main.yml")
    files["roles/r1/meta/main.yml"] = <<-YAML
      argument_specs:
        main:
          short_description: Nested
          options:
            userdata:
              type: dict
              required: true
              options:
                fqdn:
                  type: str
                  required: true
                hostname:
                  type: str
                  required: true
      YAML
    files["play.yml"] = "- hosts: all\n  gather_facts: false\n  vars:\n    userdata:\n      fqdn: host.example.com\n  roles:\n    - r1\n"
    status, output = run_playbook(files)

    status.exit_code.must_equal(2)
    output.must_include("missing required arguments: hostname found in userdata")
    output.wont_include("msg\": \"hi")
  end

  it "gives an empty list for a dict option only the tagged-list type line" do
    files = role_files("meta/main.yml")
    files["roles/r1/meta/main.yml"] = <<-YAML
      argument_specs:
        main:
          short_description: Nested
          options:
            userdata:
              type: dict
              required: true
              options:
                hostname:
                  type: str
                  required: true
      YAML
    files["play.yml"] = "- hosts: all\n  gather_facts: false\n  vars:\n    userdata: []\n  roles:\n    - r1\n"
    _, output = run_playbook(files)

    output.must_include("argument 'userdata' is of type list and we were unable to convert to dict: <class 'ansible.module_utils._internal._datatag._AnsibleTaggedList'> cannot be converted to a dict")
    output.wont_include("dictionary requested")
    output.wont_include("must be of type dict or list of dicts")
  end

  it "reports a string for a dict option as a converter failure and a sub-spec rejection" do
    files = role_files("meta/main.yml")
    files["roles/r1/meta/main.yml"] = <<-YAML
      argument_specs:
        main:
          short_description: Nested
          options:
            userdata:
              type: dict
              required: true
              options:
                hostname:
                  type: str
                  required: true
      YAML
    files["play.yml"] = "- hosts: all\n  gather_facts: false\n  vars:\n    userdata: x\n  roles:\n    - r1\n"
    _, output = run_playbook(files)

    output.must_include("argument 'userdata' is of type str and we were unable to convert to dict: dictionary requested, could not parse JSON or key=value")
    output.must_include("value of 'userdata' must be of type dict or list of dicts")
  end

  it "gives a dict option without a sub-spec only the tagged-list type line" do
    files = role_files("meta/main.yml")
    files["roles/r1/meta/main.yml"] = <<-YAML
      argument_specs:
        main:
          short_description: Nested
          options:
            userdata:
              type: dict
              required: true
      YAML
    files["play.yml"] = "- hosts: all\n  gather_facts: false\n  vars:\n    userdata:\n      - 1.1.1.1\n  roles:\n    - r1\n"
    _, output = run_playbook(files)

    output.must_include("argument 'userdata' is of type list and we were unable to convert to dict: <class 'ansible.module_utils._internal._datatag._AnsibleTaggedList'> cannot be converted to a dict")
    output.wont_include("dictionary requested")
  end

  it "quotes the value's Python repr in an int conversion failure" do
    files = role_files("meta/main.yml")
    files["roles/r1/meta/main.yml"] = <<-YAML
      argument_specs:
        main:
          short_description: Count
          options:
            count:
              type: int
              required: true
      YAML
    files["play.yml"] = "- hosts: all\n  gather_facts: false\n  vars:\n    count: notanint\n  roles:\n    - r1\n"
    _, output = run_playbook(files)

    output.must_include("argument 'count' is of type str and we were unable to convert to int: \"'notanint'\" cannot be converted to an int")
  end
end
