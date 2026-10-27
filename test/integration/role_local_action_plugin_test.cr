require "../minitest_helper"
require "file_utils"

# yourlabs.remember (issue #669) ships its only implementation as a
# role-private controller-side action plugin, action_plugins/remember.py,
# with library/remember.py left as an empty placeholder. Ansible resolves
# the action plugin first and runs it, so the play succeeds there; krikri
# has no controller-side plugin runtime and must refuse it by name rather
# than execute the empty placeholder or silently skip the task.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "role-private Python action plugin with an empty library placeholder (role_local_action_plugin_test.cr)" do
  it "fails the task with the unsupported-action-plugin message and exits non-zero" do
    root = File.tempname("role-local-action-plugin")
    Dir.mkdir_p(File.join(root, "roles", "remember", "action_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "remember", "library"))
    Dir.mkdir_p(File.join(root, "roles", "remember", "tasks"))

    File.write(File.join(root, "roles", "remember", "action_plugins", "remember.py"), <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          def run(self, tmp=None, task_vars=None):
              return dict(changed=False)
      PYTHON

    File.write(File.join(root, "roles", "remember", "library", "remember.py"), "")

    File.write(File.join(root, "roles", "remember", "tasks", "main.yml"), <<-YAML)
      - name: Seting variables for this role
        remember:
          extra: '{{ remember_extra|default({}) }}'
      YAML

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - remember
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output.to_s.must_include("role-local Python action plugin", output.to_s)
    output.to_s.must_include("is not supported by krikri", output.to_s)
  ensure
    FileUtils.rm_rf(root) if root
  end
end
