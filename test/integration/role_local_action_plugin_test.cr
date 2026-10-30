require "../minitest_helper"
require "file_utils"
require "../../src/krikri/python_action_runner"

# yourlabs.remember (issue #669) ships its only implementation as a
# role-private controller-side action plugin, action_plugins/remember.py,
# with library/remember.py left as an empty placeholder. Ansible resolves
# the action plugin first and runs it. krikri now dispatches such plugins
# through the controller's own python3 (PythonActionRunner) when the
# `ansible` package is importable there; a plugin that CRASHES is a real
# task failure carrying the plugin's own error, not the old blanket
# "not supported" refusal - so this fixture raises inside run() to pin
# the dispatched-failure behavior. On a controller without an importable
# `ansible` package the mechanism itself is unavailable and the task
# keeps the historical refusal, asserted as-is (suite green either way).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def ansible_importable : Bool
  python = Krikri::PythonActionRunner.python_executable
  return false unless python
  status = Process.run(python, ["-c", "from ansible.plugins.action import ActionBase"],
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  status.success?
end

describe "role-private Python action plugin with an empty library placeholder (role_local_action_plugin_test.cr)" do
  it "fails the task with the crashing plugin's own error and exits non-zero" do
    root = File.tempname("role-local-action-plugin")
    Dir.mkdir_p(File.join(root, "roles", "remember", "action_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "remember", "library"))
    Dir.mkdir_p(File.join(root, "roles", "remember", "tasks"))

    File.write(File.join(root, "roles", "remember", "action_plugins", "remember.py"), <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          def run(self, tmp=None, task_vars=None):
              raise Exception("boom from remember")
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
    if ansible_importable
      # The dispatched plugin's own exception text, not a generic refusal.
      output.to_s.must_include("boom from remember", output.to_s)
    else
      output.to_s.must_include("is not supported by krikri", output.to_s)
    end
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "runs an action-plugin-only role task (no library placeholder) and fails it with the plugin's own AnsibleError (issue #411)" do
    # amtega.check_platform implements its single task `_check_platform:`
    # purely through action_plugins/_check_platform.py - it ships NO
    # library/ placeholder at all. Ansible resolves the role's
    # action_plugins/ name and RUNS the plugin, whose raised AnsibleError
    # ("ubuntu distribution is not supported" on the benchmark hosts) is
    # the task's own failure: fatal msg "Task failed: <text>", action-level
    # [ERROR] chain without a "Module failed." segment, rc=2 with a recap.
    # krikri used to treat the name as an unavailable module instead
    # (skip + rc=4 at the end of the run) - the exit-code divergence this
    # pins closed.
    root = File.tempname("role-local-action-only")
    Dir.mkdir_p(File.join(root, "roles", "check_platform", "action_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "check_platform", "tasks"))

    File.write(File.join(root, "roles", "check_platform", "action_plugins", "_check_platform.py"), <<-PYTHON)
      from ansible.errors import AnsibleError
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              distributions = self._templar.template(
                  (task_vars or {}).get("check_platform_distributions", {}))
              names = [d.lower() for d in distributions.keys()]
              if "ubuntu" not in names:
                  raise AnsibleError("ubuntu distribution is not supported")
              return dict(changed=False)
      PYTHON

    File.write(File.join(root, "roles", "check_platform", "tasks", "main.yml"), <<-YAML)
      - name: Check platform
        _check_platform:
      YAML

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          check_platform_distributions:
            centos: 7
        roles:
          - check_platform
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    # A task failure (rc=2) with a full recap - never the end-of-run
    # unavailable-modules abort (rc=4).
    status.exit_code.must_equal(2, output.to_s)
    output.to_s.must_include("PLAY RECAP", output.to_s)
    output.to_s.must_include("failed=1", output.to_s)
    output.to_s.wont_include("unavailable modules", output.to_s)
    if ansible_importable
      output.to_s.must_include("Task failed: ubuntu distribution is not supported", output.to_s)
      output.to_s.wont_include("Module failed.", output.to_s)
    else
      output.to_s.must_include("is not supported by krikri", output.to_s)
    end
  ensure
    FileUtils.rm_rf(root) if root
  end
end
