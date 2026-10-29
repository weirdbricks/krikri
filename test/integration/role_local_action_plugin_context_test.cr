require "../minitest_helper"
require "file_utils"
require "../../src/krikri/python_action_runner"

# gzm55.local_ssh_known_hosts (issue #519) ships its only implementation
# as a role-private CONTROLLER-side action plugin,
# action_plugins/current_play_context_known_hosts.py, beside an empty-ish
# library/ placeholder. Ansible resolves the action plugin first and its
# run(task_vars=...) return dict IS the task result, echoing
# self._play_context's connection/remote_addr/port - so `register:` on
# the task exposes those play-context fields to later tasks. krikri now
# dispatches such plugins through the controller's own python3
# (PythonActionRunner) with stub task/connection/play_context objects
# carrying the executor's resolved connection values. On a controller
# without an importable `ansible` package the mechanism itself is
# unavailable and the task keeps the historical refusal, asserted as-is
# (suite green either way).
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

describe "role-local Python action plugin reading the play context (role_local_action_plugin_context_test.cr)" do
  it "exposes the play context's connection and remote_addr through register" do
    root = File.tempname("role-local-action-context")
    Dir.mkdir_p(File.join(root, "roles", "ctxhost", "action_plugins"))
    Dir.mkdir_p(File.join(root, "roles", "ctxhost", "library"))
    Dir.mkdir_p(File.join(root, "roles", "ctxhost", "tasks"))

    File.write(File.join(root, "roles", "ctxhost", "action_plugins", "current_play_context_known_hosts.py"), <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              if task_vars is None:
                  task_vars = dict()
              result = super(ActionModule, self).run(tmp, task_vars)
              del tmp
              ctx = self._play_context
              result['connection'] = ctx.connection
              result['remote_addr'] = ctx.remote_addr
              result['port'] = ctx.port
              result['changed'] = False
              return result
      PYTHON

    File.write(File.join(root, "roles", "ctxhost", "library", "current_play_context_known_hosts.py"), "")

    File.write(File.join(root, "roles", "ctxhost", "tasks", "main.yml"), <<-YAML)
      - name: Save context
        current_play_context_known_hosts:
        register: ctx
      - name: Show connection
        debug: var=ctx.connection
      - name: Show remote_addr
        debug: var=ctx.remote_addr
      YAML

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - ctxhost
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    if ansible_importable
      status.success?.must_equal(true, output.to_s)
      output.to_s.must_include("\"ctx.connection\": \"local\"", output.to_s)
      output.to_s.must_include("\"ctx.remote_addr\": \"localhost\"", output.to_s)
      # The plugin's own changed=False verdict: a changed result would
      # flip the recap counter.
      output.to_s.must_include("changed=0", output.to_s)
    else
      status.success?.must_equal(false, output.to_s)
      output.to_s.must_include("is not supported by krikri", output.to_s)
    end
  ensure
    FileUtils.rm_rf(root) if root
  end
end
