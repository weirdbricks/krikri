require "../minitest_helper"
require "file_utils"

# meta/argument_specs.yaml and meta/argument_specs.json were invisible to
# the validator synthesis: only the exact meta/argument_specs.yml path was
# checked before falling back to the meta main file, so roles like
# stephdewit.docker (meta/argument_specs.yaml + meta/main.yaml) got no
# "Validating arguments against arg spec 'main'" task (issue #637).
# Ansible loops YAML_FILENAME_EXTENSIONS (.yml, .yaml, .json) over
# meta/argument_specs<ext> and uses the first existing file exclusively.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private ARG_SPEC_YAML = <<-YAML
  argument_specs:
    main:
      short_description: Manage docker
      options:
        image:
          type: str
          required: true
  YAML

private def run_playbook(files : Hash(String, String)) : {Process::Status, String}
  nonce = Random::Secure.hex(4)
  dir = PluginSpecHelper.tmp_path("argspec-yaml-ext-#{nonce}")
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

private def base_role_files : Hash(String, String)
  {
    "roles/r1/tasks/main.yml" => "---\n- name: role task\n  ansible.builtin.debug:\n    msg: hi\n",
    "play.yml"                => "- hosts: all\n  gather_facts: false\n  roles:\n    - r1\n",
  }
end

describe "role argument_specs file extension discovery" do
  it "synthesizes the validation task from meta/argument_specs.yaml" do
    files = base_role_files
    files["roles/r1/meta/argument_specs.yaml"] = ARG_SPEC_YAML
    status, output = run_playbook(files)

    status.exit_code.must_equal(2)
    output.must_include("TASK [r1 : Validating arguments against arg spec 'main' - Manage docker]")
    output.must_include("missing required arguments: image")
    output.wont_include("msg\": \"hi")
  end

  it "reads meta/argument_specs.json the same way" do
    files = base_role_files
    files["roles/r1/meta/argument_specs.json"] = ARG_SPEC_YAML
    status, output = run_playbook(files)

    status.exit_code.must_equal(2)
    output.must_include("Validating arguments against arg spec 'main'")
    output.must_include("missing required arguments: image")
    output.wont_include("msg\": \"hi")
  end

  it "prefers meta/argument_specs.yml over meta/argument_specs.yaml when both exist" do
    files = base_role_files
    files["roles/r1/meta/argument_specs.yml"] = "argument_specs:\n  main:\n    options:\n      other:\n        type: str\n        required: true\n"
    files["roles/r1/meta/argument_specs.yaml"] = ARG_SPEC_YAML
    _, output = run_playbook(files)

    output.must_include("missing required arguments: other")
    output.wont_include("missing required arguments: image")
  end

  it "does not fall back to the meta main file when argument_specs.yaml has no main entry" do
    files = base_role_files
    files["roles/r1/meta/argument_specs.yaml"] = "argument_specs: {}\n"
    files["roles/r1/meta/main.yml"] = ARG_SPEC_YAML
    _, output = run_playbook(files)

    output.wont_include("Validating arguments against arg spec")
    output.must_include("msg\": \"hi")
  end
end
