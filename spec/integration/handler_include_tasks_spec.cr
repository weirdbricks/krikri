require "file_utils"
require "../spec_helper"

# Runs the compiled binary against a real playbook (a real notified
# handler using include_tasks:, not --check mode), since this bug is
# specifically about TaskExecutor#execute_handler_plugin_once, a private
# method not reachable from a unit spec without constructing a whole
# TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a handler using include_tasks:" do
  it "runs the included file's tasks instead of crashing the whole run" do
    # Real crash found benchmarking Anthony25.unbound (round828): its
    # "restart unbound" handler is `include_tasks: tasks/restart_unbound.yml`
    # - a real Ansible pattern (a handler can include a task file exactly
    # like a regular task can). #execute_handler_plugin_once only ever
    # special-cased ansible.builtin.reboot before falling through to
    # normal plugin dispatch - a handler's include_tasks: (the synthetic
    # "_include_tasks" pseudo-module, never backed by a real plugin
    # binary) hit that same fallthrough and crashed the ENTIRE run with
    # an unhandled exception ("Plugin binary not found: _include_tasks")
    # the moment the handler was notified, instead of running the
    # included file's tasks the way the regular-task include_tasks: path
    # (execute_include_tasks) already does.
    dir = File.tempname("handler-include-tasks")
    Dir.mkdir_p(File.join(dir, "tasks"))

    File.write(File.join(dir, "site.yml"), <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger the handler
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: restart thing
        handlers:
          - name: restart thing
            ansible.builtin.include_tasks: tasks/inner.yml
      YAML

    File.write(File.join(dir, "tasks", "inner.yml"), <<-YAML)
      - name: inner task
        ansible.builtin.debug:
          msg: included task ran
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, File.join(dir, "site.yml")], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("included task ran")
    output.to_s.should_not contain("Unhandled exception")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
