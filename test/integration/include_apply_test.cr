require "../minitest_helper"
require "file_utils"

# `apply:` on an include directive - ansible-core builds an implicit
# parent Block from that mapping (task_include.py's build_parent_block),
# so the tasks the include loads inherit its keywords as block-level
# defaults. This engine validated the mapping's shape at parse time and
# then dropped it, which is why pandemonium1986.ohmyzsh's
# `apply: {become: true, become_user: "{{ ... }}"}` ran the oh-my-zsh
# installer as root (HOME=/root) and lineinfile later failed with
# "Destination /home/pandemonium//.zshrc does not exist !" on a host
# where ansible-playbook succeeded.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_apply_playbook(root : String, inner_yaml : String, playbook_body : String)
  FileUtils.rm_rf(root) if Dir.exists?(root)
  Dir.mkdir_p(root)
  File.write(File.join(root, "inner.yml"), inner_yaml)
  playbook = File.join(root, "site.yml")
  File.write(playbook, playbook_body)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
end

describe "apply: keywords reach the tasks an include loads" do
  it "passes apply vars: down and gates every loaded task on apply when:" do
    root = File.tempname("include-apply-vars")
    status, output = run_apply_playbook(root,
      <<-YAML,
      - name: echo applied var
        ansible.builtin.debug:
          msg: "applied={{ applied | default('MISSING') }}"
      YAML
      <<-YAML)
      - name: apply vars/when
        hosts: localhost
        gather_facts: false
        tasks:
          - name: include with apply vars
            ansible.builtin.include_tasks:
              file: #{root}/inner.yml
              apply:
                vars:
                  applied: from_apply
          - name: include with apply when false
            ansible.builtin.include_tasks:
              file: #{root}/inner.yml
              apply:
                when: false
      YAML

    # Both shapes live-verified against ansible-playbook 2.19.11: the
    # first include's child sees the applied variable, the second one's
    # child is skipped outright - apply's when: gates the loaded task,
    # not just the include statement (which itself still reports ok).
    status.success?.must_equal(true, output)
    output.must_include(%("msg": "applied=from_apply"), output)
    output.scan("skipping: [localhost]").size.must_equal(1, output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "makes an apply become_user: apply to every loaded task" do
    root = File.tempname("include-apply-become")
    status, output = run_apply_playbook(root,
      <<-YAML,
      - name: who am i
        ansible.builtin.command: id -un
      YAML
      <<-YAML)
      - name: apply become
        hosts: localhost
        gather_facts: false
        tasks:
          - name: include with apply become_user
            ansible.builtin.include_tasks:
              file: #{root}/inner.yml
              apply:
                become: true
                become_user: nonexistent_user_xyz_12345
      YAML

    # An unknown become_user is deterministic on any machine regardless
    # of its own sudoers config (the same signal
    # connection_failure_unignorable_by_failed_when_test.cr uses): the
    # loaded task must try to escalate and fail, instead of running as
    # the invoking user the way it did before apply: was honoured.
    status.success?.must_equal(false, output)
    output.must_match(/failed=1\b/, output)
    output.must_include("sudo: unknown user nonexistent_user_xyz_12345", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "passes apply vars: into the tasks an include_role: loads" do
    root = File.tempname("include-role-apply")
    FileUtils.rm_rf(root) if Dir.exists?(root)
    role_tasks = File.join(root, "roles", "child", "tasks")
    Dir.mkdir_p(role_tasks)
    File.write(File.join(role_tasks, "main.yml"), <<-YAML)
      - name: echo applied var
        ansible.builtin.debug:
          msg: "role_applied={{ applied | default('MISSING') }}"
      YAML
    playbook = File.join(root, "site.yml")
    File.write(playbook, <<-YAML)
      - name: apply vars on include_role
        hosts: localhost
        gather_facts: false
        tasks:
          - name: include a role with apply vars
            ansible.builtin.include_role:
              name: child
              apply:
                vars:
                  applied: from_apply
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    status.success?.must_equal(true, text)
    text.must_include(%("msg": "role_applied=from_apply"), text)
  ensure
    FileUtils.rm_rf(root) if root
  end
end
