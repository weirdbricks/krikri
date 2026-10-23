require "../minitest_helper"
require "file_utils"

# The ROLE form's argument_spec itself is templated during task-arg
# finalization - `default:` expressions included - before the action
# plugin ever reads a value out of task_vars (issue #270, live-verified
# byte-for-byte against ansible-core 2.19 for kliwniloc.borgbackup: an
# option default referencing an undefined variable fails the SYNTHESIZED
# validate_argument_spec task in the finalization shape, with the [ERROR]
# chain block's Origins pointing into meta/argument_specs.yml itself).
# This engine used to unwind the other way around: the bare
# "'var' is undefined" surfaced out of the var-value templating inside
# get_args_from_task_vars, with no Finalization wrapper and no spec-file
# Origins.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_role_roleplay(play_vars : String = "") : {Process::Status, String}
  dir = File.tempname("argspec-final", ".d")
  Dir.mkdir(dir)
  role = File.join(dir, "roles", "argspec270")
  FileUtils.mkdir_p(File.join(role, "meta"))
  FileUtils.mkdir_p(File.join(role, "tasks"))
  # first_opt is a required option at the TOP of the spec (its key is the
  # stanza-3 Origin line); the failing templated default sits on a LATER
  # option so the Origins provably don't collapse onto one line.
  File.write(File.join(role, "meta", "argument_specs.yml"), <<-YAML
    ---
    argument_specs:
      main:
        options:
          first_opt:
            type: str
            required: true
          second_opt:
            type: str
            default: "{{ no_such_var }}"
    YAML
  )
  File.write(File.join(role, "tasks", "main.yml"), "---\n- name: past validation\n  ansible.builtin.debug:\n    msg: \"PAST-VALIDATION\"\n")
  playbook = File.join(dir, "play.yml")
  File.write(playbook, <<-YAML
    - hosts: localhost
      connection: local
      gather_facts: false
      #{play_vars}
      roles:
        - role: argspec270
    YAML
  )
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "validate_argument_spec role-spec finalization templating failure" do
  it "fails at finalization with the spec-file chain block before any var-value templating" do
    status, output = run_role_roleplay

    status.exit_code.must_equal(2)
    # The finalization shape, not the bare var-value shape the engine used
    # to print (the whole point of issue #270).
    output.must_include("Finalization of task args for 'ansible.builtin.validate_argument_spec' failed:")
    output.wont_include("Task failed: 'no_such_var' is undefined")
    # The required check never runs: spec templating comes first.
    output.wont_include("missing required arguments")
    output.must_include("failed=1")
    output.wont_include("PAST-VALIDATION")

    # Stanza 1: headline + Task failed./Origin <unknown> + the shortened
    # action-call repr.
    output.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.validate_argument_spec' failed: Error while resolving value for 'argument_spec': 'no_such_var' is undefined")
    output.must_include("Task failed.\nOrigin: <unknown>\n")
    output.must_include("'action': 'ansible.builtin.validate_argument_spec'")
    # Stanza 2: the finalization wrapper with the bare action name as
    # its origin-less body.
    output.must_include("Finalization of task args for 'ansible.builtin.validate_argument_spec' failed.\nOrigin: <unknown>\n\nansible.builtin.validate_argument_spec\n")
    # Stanza 3/4: Origins inside the spec file - first option's key line
    # for the resolvable-argument failure, the failing option's default
    # value token for the undefined-variable cause.
    output.must_include("argument_specs.yml:5:7")
    output.must_include("\n3   main:\n4     options:\n5       first_opt:\n        ^ column 7\n")
    output.must_include("argument_specs.yml:10:18")
    output.must_include("\n 8       second_opt:\n 9         type: str\n10         default: \"{{ no_such_var }}\"\n                    ^ column 18\n")

    # The block precedes the fatal line, whose msg is the finalization
    # wrapper only.
    err_idx = output.index("[ERROR]: Task failed: Finalization of task args") || 0
    fatal_idx = output.index("fatal: [localhost]: FAILED!") || 0
    (err_idx < fatal_idx).must_equal(true)
    output.must_include("\"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.validate_argument_spec' failed: Error while resolving value for 'argument_spec': 'no_such_var' is undefined\"")
  end

  it "fails the same way even when the option itself is provided on the play" do
    # Real templates the spec at finalization BEFORE considering the
    # option's presence (lablabs.rke2, live-verified 2.19.4).
    status, output = run_role_roleplay(play_vars: "vars:\n    first_opt: x\n")

    status.exit_code.must_equal(2)
    output.must_include("Task failed: Finalization of task args for 'ansible.builtin.validate_argument_spec' failed: Error while resolving value for 'argument_spec': 'no_such_var' is undefined")
    output.wont_include("PAST-VALIDATION")
    output.must_include("failed=1")
  end

  it "passes the role through untouched when every spec default resolves" do
    status, output = run_role_roleplay(play_vars: "vars:\n    first_opt: x\n    no_such_var: now_defined\n")

    status.success?.must_equal(true)
    output.must_include("PAST-VALIDATION")
    output.must_include("failed=0")
    output.wont_include("Finalization of task args for 'ansible.builtin.validate_argument_spec'")
  end
end
