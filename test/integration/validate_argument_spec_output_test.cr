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

  it "registers the passing inline task's result so a later when: can read it" do
    # Real 2.19.11 registers the action's own result (changed/failed/msg/
    # validate_args_context) on a user-written validate_argument_spec task
    # - issue #1080: the register used to stay undefined, killing a later
    # `when: <reg> is not skipped` with an undefined-name error.
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec: {}\n      register: kpg_task_0\n      ignore_errors: true\n    - name: Wait for connection\n      ansible.builtin.debug:\n        msg: ran\n      when: kpg_task_0 is not skipped\n",
    })

    status.exit_code.must_equal(0)
    output.must_include("ok: [localhost]")
    output.must_include("\"msg\": \"ran\"")
    output.must_include("failed=0")
    output.wont_include("'kpg_task_0' is undefined")
  end

  it "carries msg and validate_args_context in the registered success shape" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec: {}\n      register: res\n    - ansible.builtin.debug:\n        var: res\n",
    })

    status.exit_code.must_equal(0)
    output.must_include(%q("changed": false))
    output.must_include(%q("failed": false))
    output.must_include(%q("msg": "The arg spec validation passed"))
    output.must_include(%q("validate_args_context": {}))
  end

  it "registers the skipped shape when the inline task's when: is false" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec: {}\n      register: res\n      when: false\n    - ansible.builtin.debug:\n        var: res\n      when: res is not skipped\n      ignore_errors: true\n",
    })

    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]")
    output.wont_include("'res' is undefined")
  end

  it "satisfies an inline required option from a play var (combine_vars semantics)" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  vars:\n    a: from_var\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec:\n          a: {type: str, required: true}\n    - ansible.builtin.debug:\n        msg: after\n",
    })

    status.exit_code.must_equal(0)
    output.must_include("\"msg\": \"after\"")
  end

  it "registers a passing inline task's result for a later when: gate (issue #1081)" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec: {}\n        provided_arguments: {}\n      register: kpg_task_0\n      ignore_errors: true\n    - name: gated on register\n      ansible.builtin.debug:\n        msg: ran\n      when: kpg_task_0 is not skipped\n    - ansible.builtin.debug:\n        var: kpg_task_0\n",
    })

    status.exit_code.must_equal(0)
    # The registered var must exist for the when: - krikri used to leave it
    # undefined and fail the gate with "'kpg_task_0' is undefined".
    output.wont_include("'kpg_task_0' is undefined")
    output.must_include("\"msg\": \"ran\"")
    # Real's registered passing shape carries the msg the display omits
    # (live-verified vs 2.19.11).
    output.must_include("\"msg\": \"The arg spec validation passed\"")
  end

  it "registers a failing inline task's result under ignore_errors for a later when: gate" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Validating arguments\n      ansible.builtin.validate_argument_spec:\n        argument_spec:\n          a: {type: str, required: true}\n      register: kpg_task_1\n      ignore_errors: true\n    - name: gated on register\n      ansible.builtin.debug:\n        msg: ran\n      when: kpg_task_1 is not skipped\n",
    })

    status.exit_code.must_equal(0)
    output.wont_include("'kpg_task_1' is undefined")
    output.must_include("\"msg\": \"ran\"")
    output.must_include("ignored=1")
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

  it "fails a plain-string argument_spec with the action's Incorrect type brief (issue #764)" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  tasks:\n    - name: 'validate_argument_spec #0'\n      ansible.builtin.validate_argument_spec:\n        argument_spec: ojgkdl\n      ignore_errors: true\n",
    })

    # Real 2.19.11: the action plugin's own AnsibleActionFail renders the
    # collapsed one-segment [ERROR] chain at the task's Origin, the
    # "Task failed: " brief in the fatal msg, then "...ignoring" - the
    # recap's ignored=1 (not ok) is what the generator's recap comparison
    # caught. A plain string rides real's chain templar unchanged, so even
    # a JSON-shaped one stays a tagged str.
    status.exit_code.must_equal(0)
    output.must_include("[ERROR]: Task failed: Incorrect type for argument_spec, expected dict and got <class 'ansible.module_utils._internal._datatag._AnsibleTaggedStr'>")
    output.must_include("pb.yml:4:7")
    output.must_include("^ column 7")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Incorrect type for argument_spec, expected dict and got <class 'ansible.module_utils._internal._datatag._AnsibleTaggedStr'>\"}")
    output.must_include("...ignoring")
    output.must_include("ignored=1")
    output.wont_include("ok: [localhost]")
  end

  it "names the resolved value's own class for each non-mapping argument_spec shape (issue #764)" do
    status, output = run_playbook("pb.yml", {
      "pb.yml" => "- hosts: all\n  gather_facts: false\n  vars:\n    spec_str: ojgkdl\n  tasks:\n    - name: list spec\n      ansible.builtin.validate_argument_spec:\n        argument_spec: [a, b]\n      ignore_errors: true\n    - name: int spec\n      ansible.builtin.validate_argument_spec:\n        argument_spec: 3\n      ignore_errors: true\n    - name: bool spec\n      ansible.builtin.validate_argument_spec:\n        argument_spec: true\n      ignore_errors: true\n    - name: none spec\n      ansible.builtin.validate_argument_spec:\n        argument_spec: null\n      ignore_errors: true\n    - name: jinja resolving to string\n      ansible.builtin.validate_argument_spec:\n        argument_spec: \"{{ spec_str }}\"\n      ignore_errors: true\n",
    })

    # The class name follows the VALUE's type, not its content: bools ride
    # untagged, an explicit null is NoneType, ints/lists the tagged
    # subclasses, and a template resolving to a string fails as a tagged
    # str (live-verified vs 2.19.11).
    status.exit_code.must_equal(0)
    output.must_include("<class 'ansible.module_utils._internal._datatag._AnsibleTaggedList'>")
    output.must_include("<class 'ansible.module_utils._internal._datatag._AnsibleTaggedInt'>")
    output.must_include("<class 'bool'>")
    output.must_include("<class 'NoneType'>")
    output.wont_include("ok: [localhost]")
    output.must_include("ignored=5")
  end
end
