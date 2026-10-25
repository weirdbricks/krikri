require "../minitest_helper"
require "file_utils"

# A tombstone-removed module (community.docker.docker_compose) reached at
# RUN time through include_tasks: or include_role: is the include task's
# own fatal failure in Ansible, NOT the whole-run playbook-load refusal a
# top-level occurrence is: the [ERROR]+Origin block goes to STDERR once,
# then one fatal: line per host, failed=1 in the recap, the play halts
# for that host, ignore_errors does not apply, rc=2 (live-verified vs
# ansible-core 2.19.x). include_tasks dumps the as-written path under
# "include:"; include_role dumps only changed+reason.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private REMOVED_TASKS = <<-YAML
  - name: removed module
    community.docker.docker_compose:
      project_src: /tmp/x
  YAML

private def run_removed_include_playbook(files : Hash(String, String)) : {Process::Status, String}
  root = File.tempname("removed-module-include")
  Dir.mkdir_p(root)
  files.each do |rel, content|
    path = File.join(root, rel)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: captured, error: captured, chdir: root)
  {status, captured.to_s}
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

describe "removed module reached at run time through a dynamic include" do
  it "fails the include_tasks task itself instead of hard-stopping the whole run" do
    status, output = run_removed_include_playbook({
      "pb.yml" => <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: include the removed module
              ansible.builtin.include_tasks: install.yml
        YAML
      "install.yml" => REMOVED_TASKS,
    })
    status.success?.must_equal(false, output)
    status.exit_code.must_equal(2, output)
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"include\": \"install.yml\"", output)
    output.must_include("failed=1", output)
    output.must_include("PLAY RECAP", output)
    output.must_include("<<< caused by >>>", output)
    output.scan("has been removed. This module").size.must_equal(4, output)
    output.must_include("Origin:", output)
    output.must_include("install.yml:1:3", output)
    output.wont_include("Failed to load", output)
  end

  it "fails the include_tasks task itself when the loaded file uses the removed bare include:" do
    status, output = run_removed_include_playbook({
      "pb.yml" => <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: include mount tasks
              include_tasks: mount.yml
        YAML
      "mount.yml" => "---\n- include: \"lookup.yml\"\n",
    })
    status.exit_code.must_equal(2, output)
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"include\": \"mount.yml\"", output)
    output.must_include("<<< caused by >>>", output)
    output.must_include("mount.yml:2:3", output)
    output.must_include("failed=1", output)
    output.wont_include("Failed to load", output)
  end

  it "dumps the rendered include path, not the template, in the fatal line" do
    status, output = run_removed_include_playbook({
      "pb.yml" => <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          vars:
            action: mount
          tasks:
            - name: include mount tasks
              include_tasks: "{{ action }}.yml"
        YAML
      "mount.yml" => "---\n- include: \"lookup.yml\"\n",
    })
    status.exit_code.must_equal(2, output)
    output.must_include("\"include\": \"mount.yml\"", output)
    output.wont_include("{{ action }}.yml\", \"reason\"", output)
  end

  it "fails the include_role task itself with only changed+reason in the dump" do
    status, output = run_removed_include_playbook({
      "pb.yml" => <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: include the removed module role
              ansible.builtin.include_role:
                name: harbor
                tasks_from: install
        YAML
      "roles/harbor/tasks/install.yml" => REMOVED_TASKS,
    })
    status.success?.must_equal(false, output)
    status.exit_code.must_equal(2, output)
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"reason\": ", output)
    output.must_include("failed=1", output)
    output.must_include("PLAY RECAP", output)
    fatal_lines = output.lines.select(&.includes?("fatal: [localhost]"))
    fatal_lines.size.must_equal(1, output)
    fatal_lines.first.wont_include("\"include\"", output)
  end
end
