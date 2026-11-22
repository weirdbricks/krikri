require "../minitest_helper"
require "file_utils"

# A tombstone-removed module (community.docker.docker_compose) or a removed
# bare `include:` reached at RUN time through include_tasks: or include_role:
# is the include task's own fatal failure in Ansible, NOT the whole-run
# playbook-load refusal a top-level occurrence is: the [ERROR]+Origin block
# goes to STDOUT once, then one fatal: line per host carrying only
# changed+msg, failed=1 in the recap, the play halts for that host,
# ignore_errors does not apply, rc=2 (live-verified vs ansible-core 2.21.6).
# 2.19's stderr three-message "<<< caused by >>>" chain and its
# include/reason dump are both gone.
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
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"The 'community.docker.docker_compose' module has been removed.", output)
    output.must_include("failed=1", output)
    output.must_include("PLAY RECAP", output)
    output.wont_include("<<< caused by >>>", output)
    output.wont_include("\"reason\"", output)
    # Once as the error block's headline, once as the fatal result's msg.
    output.scan("has been removed. This module").size.must_equal(2, output)
    output.must_include("Origin:", output)
    output.must_include("install.yml:1:3", output)
    output.wont_include("Failed to load", output)
    # The block is the task result's own exception: real prints it after the
    # banner and ahead of the fatal line, both on STDOUT.
    error_idx = output.index("[ERROR]: The 'community.docker.docker_compose'").not_nil!(output)
    fatal_idx = output.index("fatal: [localhost]").not_nil!(output)
    (error_idx < fatal_idx).must_equal(true, output)
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
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"The 'ansible.builtin.include' action plugin has been removed.", output)
    output.wont_include("<<< caused by >>>", output)
    output.wont_include("\"reason\"", output)
    output.must_include("mount.yml:2:3", output)
    output.must_include("failed=1", output)
    output.wont_include("Failed to load", output)
  end

  it "reports the loaded file's Origin for a templated include path" do
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
    output.must_include("Origin:", output)
    output.must_include("mount.yml:2:3", output)
    output.wont_include("{{ action }}", output)
  end

  it "fails the include_role task itself with the changed+msg dump" do
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
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"The 'community.docker.docker_compose' module has been removed.", output)
    output.must_include("failed=1", output)
    output.must_include("PLAY RECAP", output)
    output.wont_include("<<< caused by >>>", output)
    fatal_lines = output.lines.select(&.includes?("fatal: [localhost]"))
    fatal_lines.size.must_equal(1, output)
    fatal_lines.first.wont_include("\"include\"", output)
    fatal_lines.first.wont_include("\"reason\"", output)
  end

  it "fails the include_role task itself when the role's tasks use the removed bare include:" do
    status, output = run_removed_include_playbook({
      "pb.yml" => <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: include the broken role
              ansible.builtin.include_role:
                name: broken
        YAML
      "roles/broken/tasks/main.yml" => "---\n- include: \"lookup.yml\"\n",
    })
    status.exit_code.must_equal(2, output)
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"The 'ansible.builtin.include' action plugin has been removed.", output)
    output.wont_include("Failed to load", output)
    output.wont_include("<<< caused by >>>", output)
    output.must_include("roles/broken/tasks/main.yml:2:3", output)
    output.must_include("failed=1", output)
  end

  # A LOOPED include_tasks: whose item file carries a removed module fails
  # at the item's task load: Ansible prints only the [ERROR]+Origin block -
  # NO per-item fatal: line (unlike the non-looped shapes above), the
  # earlier items stay credited ok, the failing item recaps failed=1 and
  # the play halts for the host (live-verified vs 2.21.6).
  it "prints no per-item fatal line when a looped include's item file carries a removed module" do
    status, output = run_removed_include_playbook({
      "pb.yml" => <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - include_tasks: "{{ item }}"
              with_items:
                - "first.yml"
                - "install.yml"
        YAML
      "first.yml"   => "---\n- command: \"true\"\n  changed_when: false\n",
      "install.yml" => REMOVED_TASKS,
    })
    status.success?.must_equal(false, output)
    status.exit_code.must_equal(2, output)
    output.must_include("included: ", output)
    output.wont_include("<<< caused by >>>", output)
    output.must_include("Origin:", output)
    output.must_include("install.yml:1:3", output)
    output.wont_include("Failed to load", output)
    output.wont_include("fatal: [localhost]", output)
    recap = output.lines.reverse!.find(&.includes?("localhost"))
    recap.to_s.must_match(/ok=1\s+changed=0\s+unreachable=0\s+failed=1/, output)
  end

  it "prints no per-item fatal line when a looped include's item file uses the removed bare include:" do
    status, output = run_removed_include_playbook({
      "pb.yml" => <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - include_tasks: "{{ item }}"
              with_items:
                - "mount.yml"
        YAML
      "mount.yml" => "---\n- include: \"lookup.yml\"\n",
    })
    status.exit_code.must_equal(2, output)
    output.wont_include("<<< caused by >>>", output)
    output.must_include("mount.yml:2:3", output)
    output.wont_include("Failed to load", output)
    output.wont_include("fatal: [localhost]", output)
    recap = output.lines.reverse!.find(&.includes?("localhost"))
    recap.to_s.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1/, output)
  end
end
