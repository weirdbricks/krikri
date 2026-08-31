require "file_utils"
require "../spec_helper"

# Runs the compiled binary against a real playbook, since this bug is
# specifically about TaskExecutor#run_include_tasks_once's file-parsing
# rescue path, not reachable from a unit spec without constructing a
# whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "include_tasks: targeting a comment-only (blank) tasks file" do
  it "runs zero tasks instead of failing the whole run" do
    # Real bug found benchmarking ansistrano.deploy (round826): its
    # tasks/main.yml does `include_tasks: "{{ ansistrano_before_setup_
    # tasks_file | default('empty.yml') }}"` at 10 different hook
    # points, all defaulting to the same deliberately-empty tasks/
    # empty.yml (a comment-only no-op file the role itself ships for
    # exactly this "no custom hook" case). YAML.parse returns a bare
    # `nil` document for comment-only content, not an empty array -
    # this engine's `unless yaml.as_a?` check (written for a genuinely
    # malformed file) treated `nil` the same way, failing the whole
    # task ("Included tasks file must be a YAML list") instead of
    # running zero tasks, matching real Ansible.
    dir = File.tempname("include-tasks-empty-file")
    Dir.mkdir_p(dir)

    File.write(File.join(dir, "empty.yml"), "# intentionally empty\n")
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: before hook
            ansible.builtin.include_tasks: empty.yml
          - name: real task
            ansible.builtin.debug:
              msg: after include
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, File.join(dir, "site.yml")], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("after include")
    output.to_s.should_not contain("must be a YAML list")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
