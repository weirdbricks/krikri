require "file_utils"
require "../minitest_helper"

# include_tasks: with a failing templated path must fail the include task
# ITSELF at task-args finalization, matching Ansible (live-verified vs
# ansible-core 2.19.11 with a minimal repro: `include_tasks:
# "{{ state }}.yml"` with no `state` anywhere fails with "Error while
# resolving value for '_raw_params': 'state' is undefined", rc=2, and an
# [ERROR] chain whose task-level Origin points at the `name:` key).
#
# This engine used to render the path leniently to the literal text
# "undefined" and fail with "Could not find or access 'undefined.yml'"
# instead.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("include-tasks-undefined-path", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "include_tasks: with a failing templated path" do
  it "fails the include task at finalization when the path variable is undefined" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: "Desired state is {{ state }}"
            ansible.builtin.include_tasks: "{{ state }}.yml"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Finalization of task args for 'ansible.builtin.include_tasks' failed: Error while resolving value for '_raw_params': 'state' is undefined")
    output.wont_include("undefined.yml")
  end

  it "points the innermost Origin at the file: value's quote in dict form" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: "Desired state is {{ state }}"
            ansible.builtin.include_tasks:
              file: "{{ state }}.yml"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Error while resolving value for '_raw_params': 'state' is undefined")
    output.must_match(/Origin: \S+\.yml:7:15\n/)
    output.must_include(" " * 16 + "^ column 15\n")
  end
end
