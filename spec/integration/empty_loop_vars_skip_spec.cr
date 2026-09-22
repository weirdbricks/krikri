require "../spec_helper"
require "file_utils"

# A looped task's (or looped include_tasks:'s) own `vars:` block must only
# ever be evaluated per ACTUAL loop iteration - real Ansible never evaluates
# it at all when the loop resolves to zero items, so the whole task is a
# plain skip. krikri's build_vars_context rendered the vars: block eagerly,
# before the loop's iteration count was ever consulted, with `item` still
# unbound: a role-local filter that raises on None
# (stackhpc.luks's `item | luks_key` doing `device["device"]` on None -
# round 960004, `with_items: "{{ luks_devices }}"` over the role's empty
# `luks_devices: []` default) turned a should-be-skipped task into
# failed=1 where real ansible-playbook recaps skipped=1. A filter that
# raises on its (None) argument surfaces as FilterFailureError - a
# subclass of UnknownFilterError - which render_task_vars deliberately
# re-raises for non-looped tasks, so only a live run against a real
# role-local filter plugin can prove the looped shapes stay clean.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def write_role_with_raising_filter(root : String, tasks_body : String) : Nil
  Dir.mkdir_p(File.join(root, "roles", "myrole", "filter_plugins"))
  Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
  Dir.mkdir_p(File.join(root, "roles", "myrole", "defaults"))
  File.write(File.join(root, "roles", "myrole", "filter_plugins", "keyfilters.py"), <<-PYTHON)
    class FilterModule(object):
        def filters(self):
            return {"keyify": self.keyify}

        def keyify(self, device):
            return device["device"].replace('/', '-')[1:]
    PYTHON
  File.write(File.join(root, "roles", "myrole", "defaults", "main.yml"), <<-YAML)
    devices: []
    YAML
  File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), tasks_body)
end

private def run_role(root : String, extra_play_vars : String = "") : {Process::Status, String}
  playbook = <<-YAML
    - hosts: localhost
      connection: local
      gather_facts: false
      roles:
        - myrole
    YAML
  playbook = playbook.sub("  roles:", "#{extra_play_vars}\n  roles:") unless extra_play_vars.empty?
  File.write(File.join(root, "pb.yml"), playbook)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
  {status, output.to_s}
end

describe "zero-iteration loop never evaluates the task's own vars: block" do
  it "plain looped task over an empty list skips cleanly (skipped=1, failed=0)" do
    root = File.tempname("empty-loop-plain-task-vars")
    write_role_with_raising_filter(root, <<-YAML)
      - name: looped task whose vars reference item
        ansible.builtin.debug:
          msg: "item {{ item }} key {{ keyname }}"
        vars:
          keyname: "{{ item | keyify }}"
        with_items: "{{ devices }}"
      - name: after
        ansible.builtin.debug:
          msg: still running
      YAML

    status, output = run_role(root)

    status.success?.should be_true, output
    output.should_not contain("is not subscriptable"), output
    output.should_not contain("keyify"), output
    output.should contain("skipping: [localhost]"), output
    output.should contain("skipped=1"), output
    output.should contain("failed=0"), output
    output.should contain("still running"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "looped include_tasks: statement over an empty list skips cleanly (skipped=1, failed=0)" do
    root = File.tempname("empty-loop-include-tasks-vars")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "tasks", "keysetup.yml"), <<-YAML)
      - name: included task
        ansible.builtin.debug:
          msg: "included ran for {{ keyname }}"
      YAML
    write_role_with_raising_filter(root, <<-YAML)
      - include_tasks: keysetup.yml
        vars:
          keyname: "{{ item | keyify }}"
        with_items: "{{ devices }}"
      - name: after
        ansible.builtin.debug:
          msg: still running
      YAML

    status, output = run_role(root)

    status.success?.should be_true, output
    output.should_not contain("is not subscriptable"), output
    output.should_not contain("keyify"), output
    output.should contain("skipping: [localhost]"), output
    output.should contain("skipped=1"), output
    output.should contain("failed=0"), output
    output.should contain("still running"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  # round962000 (stackhpc.luks confirm-phase re-run after the original
  # loop_lenient_vars fix): a THIRD, un-flagged build_vars_context call
  # site - loop_source_vars_context's own alias-free rebuild, taken only
  # when a legacy ansible_ssh_* spelling is in scope - re-rendered the
  # same vars: block strictly. FilterFailureError is an UnknownFilterError
  # subclass, which render_task_vars deliberately RE-RAISES when not
  # lenient, so instead of a graceful failed=1 the whole process died with
  # an unhandled exception. This context is built for resolving the loop
  # SOURCE itself, so `item` is doubly unbound here. An ansible_ssh_ var
  # in scope is what selects this rebuild path (otherwise
  # loop_source_vars_context early-returns the caller's lenient context
  # and the two examples above already pass), so both loop shapes get a
  # variant that forces it.
  it "looped include_tasks: over an empty list skips cleanly even when the alias-free loop-source rebuild is taken" do
    root = File.tempname("empty-loop-include-tasks-alias-rebuild-vars")
    Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
    File.write(File.join(root, "roles", "myrole", "tasks", "keysetup.yml"), <<-YAML)
      - name: included task
        ansible.builtin.debug:
          msg: "included ran for {{ keyname }}"
      YAML
    write_role_with_raising_filter(root, <<-YAML)
      - include_tasks: keysetup.yml
        vars:
          keyname: "{{ item | keyify }}"
        with_items: "{{ devices }}"
      - name: after
        ansible.builtin.debug:
          msg: still running
      YAML

    status, output = run_role(root, "  vars:\n    ansible_ssh_user: admin")

    status.success?.should be_true, output
    output.should_not contain("is not subscriptable"), output
    output.should_not contain("keyify"), output
    output.should contain("skipping: [localhost]"), output
    output.should contain("skipped=1"), output
    output.should contain("failed=0"), output
    output.should contain("still running"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "plain looped task over an empty list skips cleanly even when the alias-free loop-source rebuild is taken" do
    root = File.tempname("empty-loop-plain-task-alias-rebuild-vars")
    write_role_with_raising_filter(root, <<-YAML)
      - name: looped task whose vars reference item
        ansible.builtin.debug:
          msg: "item {{ item }} key {{ keyname }}"
        vars:
          keyname: "{{ item | keyify }}"
        with_items: "{{ devices }}"
      - name: after
        ansible.builtin.debug:
          msg: still running
      YAML

    status, output = run_role(root, "  vars:\n    ansible_ssh_user: admin")

    status.success?.should be_true, output
    output.should_not contain("is not subscriptable"), output
    output.should_not contain("keyify"), output
    output.should contain("skipping: [localhost]"), output
    output.should contain("skipped=1"), output
    output.should contain("failed=0"), output
    output.should contain("still running"), output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "a NON-empty loop still evaluates the vars: per item with item bound (no over-leniency)" do
    root = File.tempname("nonempty-loop-task-vars")
    write_role_with_raising_filter(root, <<-YAML)
      - name: looped task whose vars reference item
        ansible.builtin.debug:
          msg: "key {{ keyname }}"
        vars:
          keyname: "{{ item | keyify }}"
        with_items: "{{ devices }}"
      - name: after
        ansible.builtin.debug:
          msg: still running
      YAML
    File.write(File.join(root, "roles", "myrole", "defaults", "main.yml"), <<-YAML)
      devices:
        - device: /dev/sdb
      YAML

    status, output = run_role(root)

    status.success?.should be_true, output
    output.should contain("key dev-sdb"), output
    output.should contain("failed=0"), output
  ensure
    FileUtils.rm_rf(root) if root
  end
end
