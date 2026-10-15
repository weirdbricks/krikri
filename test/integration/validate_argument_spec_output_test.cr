require "../minitest_helper"
require "file_utils"

# ansible.builtin.validate_argument_spec output parity (issue #103,
# live-verified byte-for-byte against ansible-core 2.19.11):
#
# - Gap A (role-synthesized task): a role with meta/argument_specs.yml
#   failing validation prints the [ERROR] chain block before the fatal
#   line (headline "Task failed: Action failed: Validation of arguments
#   failed: ...", an "Origin: <unknown>" segment, the shortened
#   python-repr of the action call) and the fatal result carries
#   argument_spec_data + validate_args_context.
# - Gap B (inline user task): `validate_argument_spec:` (any spelling)
#   is a real controller-side task, not a skipped unknown module - a
#   failing one prints the [ERROR] block with the task's own source
#   Origin and validate_args_context {}, a passing one prints bare ok.
#   The inline form validates combine_vars(task_vars, provided_arguments)
#   like the role form - a play var satisfies an inline required option
#   (verified in the 2.19.11 action plugin source and live).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(playbook : String, files : Hash(String, String)) : {Process::Status, String}
  dir = File.tempname("validate-argspec", ".d")
  Dir.mkdir(dir)
  files.each do |path, content|
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, File.join(dir, playbook)], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

private ROLE_SPEC = <<-YAML
  argument_specs:
    main:
      short_description: Ansible role to install X
      options:
        a:
          type: str
          required: true
        b:
          type: str
          default: x
  YAML

describe "validate_argument_spec output parity" do
  it "prints the [ERROR] block and result context keys on role-spec validation failure" do
    status, output = run_playbook("play.yml", {
      "roles/r1/meta/argument_specs.yml" => ROLE_SPEC,
      "roles/r1/tasks/main.yml"          => "---\n- ansible.builtin.debug:\n    msg: hi\n",
      "play.yml"                         => "- hosts: all\n  gather_facts: false\n  roles:\n    - r1\n",
    })

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Action failed: Validation of arguments failed:")
    output.must_include("missing required arguments: a")
    output.must_include("Origin: <unknown>")
    output.must_include("'action': 'ansible.builtin.validate_argument_spec'")
    output.must_include(%q("argument_spec_data": {"a": {"required": true, "type": "str"}, "b": {"default": "x", "type": "str"}}))
    output.must_include(%q("validate_args_context": {"argument_spec_name": "main", "name": "r1", "path": ))
    output.must_include(%q("type": "role"}))
    # The [ERROR] block precedes the fatal line.
    err_idx = output.index("[ERROR]: Task failed:") || 0
    fatal_idx = output.index("fatal: [localhost]: FAILED!") || 0
    (err_idx < fatal_idx).must_equal(true)
    output.wont_include("msg: hi")
  end

  it "keeps the passing role-spec task a bare ok with no extra result keys" do
    status, output = run_playbook("play.yml", {
      "roles/r1/meta/argument_specs.yml" => ROLE_SPEC,
      "roles/r1/tasks/main.yml"          => "---\n- ansible.builtin.debug:\n    msg: hi\n",
      "play.yml"                         => "- hosts: all\n  gather_facts: false\n  vars:\n    a: hi\n  roles:\n    - r1\n",
    })

    status.exit_code.must_equal(0)
    output.must_include("ok: [localhost]")
    output.wont_include("argument_spec_data")
  end

  it "prints the task-source [ERROR] Origin block and empty context on inline failure" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec:\n          a: {type: str, required: true}\n          b: {type: str, default: x}\n",
    })

    status.exit_code.must_equal(2)
    output.must_include("TASK [Validating arguments]")
    output.must_include("[ERROR]: Task failed: Action failed: Validation of arguments failed:")
    output.must_include("missing required arguments: a")
    # Origin pins the task's own `name:` key (line 4, column 7).
    output.must_include("Origin: ")
    output.must_include("pb.yml:4:7")
    output.must_include("4     - name: Validating arguments")
    output.must_include("^ column 7")
    output.must_include(%q("argument_spec_data": {"a": {"required": true, "type": "str"}, "b": {"default": "x", "type": "str"}}))
    output.must_include(%q("validate_args_context": {}))
    output.wont_include("skipping: [localhost]")
  end

  it "prints a bare ok for an inline passing task and still runs later tasks" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec:\n          a: {type: str, required: true}\n          b: {type: str, default: x}\n        provided_arguments:\n          a: hello\n    - ansible.builtin.debug:\n        msg: after\n",
    })

    status.exit_code.must_equal(0)
    output.must_include("ok: [localhost]")
    output.must_include("\"msg\": \"after\"")
    output.must_include("failed=0")
  end

  it "satisfies an inline required option from a play var (combine_vars semantics)" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  vars:\n    a: from_var\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec:\n          a: {type: str, required: true}\n    - ansible.builtin.debug:\n        msg: after\n",
    })

    status.exit_code.must_equal(0)
    output.must_include("\"msg\": \"after\"")
  end

  it "rejects an inline provided key the spec does not declare" do
    _, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec:\n          a: {type: str, required: true}\n        provided_arguments:\n          b: nope\n      ignore_errors: true\n",
    })

    # Failed but ignored: real's UnsupportedError wording (the
    # arg-spec-validator shape has no "Unsupported parameters" prefix),
    # then "...ignoring", not a host halt.
    output.must_include("b. Supported parameters include: a.")
    output.must_include("...ignoring")
  end

  it "accepts the bare and ansible.legacy spellings of the inline task" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Short spelling\n      validate_argument_spec:\n        argument_spec:\n          a: {type: str, required: true}\n        provided_arguments:\n          a: x\n    - name: Legacy spelling\n      ansible.legacy.validate_argument_spec:\n        argument_spec:\n          a: {type: str, required: true}\n        provided_arguments:\n          a: y\n",
    })

    status.exit_code.must_equal(0)
    output.must_include("failed=0")
  end

  it "resolves an inline Jinja-string argument_spec at execution time" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  vars:\n    spec: {a: {type: str, required: True}}\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec: \"{{ spec }}\"\n        provided_arguments:\n          a: z\n",
    })

    status.exit_code.must_equal(0)
    output.must_include("failed=0")
  end
end
