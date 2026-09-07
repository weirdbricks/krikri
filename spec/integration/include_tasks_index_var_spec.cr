require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook: run_include_tasks_once/
# run_include_role_once (executor_blocks_includes.cr) are private methods
# not reachable from a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "include_tasks: loop_control.index_var propagation into the included file" do
  it "makes the index_var available to tasks INSIDE the included file, not just the include_tasks: task's own vars:/name" do
    # Real bug found benchmarking riemers.gitlab-runner's own
    # "Write config section for each runner" task (loop_control: {loop_var:
    # runner_config, index_var: runner_config_index}, include_tasks:
    # config-runner.yml): only item/loop_var got propagated into each
    # included task's own vars, never index_var. The include_tasks: task's
    # own name/vars: (rendered against vars_context directly) resolved
    # runner_config_index fine, masking the gap until a task INSIDE the
    # included file referenced it directly and got "'runner_config_index'
    # is undefined".
    tasks_dir = File.tempname("include-index-var")
    Dir.mkdir_p(tasks_dir)
    included_file = File.join(tasks_dir, "inner.yml")
    File.write(included_file, <<-YAML)
      - name: "make temp {{ cfg_index }}"
        ansible.builtin.tempfile:
          state: file
          prefix: "myprefix.{{ cfg_index }}."
        register: tmp_result
        changed_when: false
      YAML

    playbook = File.tempname("include-index-var", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: loop with index_var
            ansible.builtin.include_tasks: #{included_file}
            loop: ["a", "b"]
            loop_control:
              loop_var: cfg_item
              index_var: cfg_index
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should_not contain("undefined")
    output.to_s.should contain("make temp 0")
    output.to_s.should contain("make temp 1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    FileUtils.rm_rf(tasks_dir) if tasks_dir
  end
end
