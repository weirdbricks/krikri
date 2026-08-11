require "../spec_helper"

# Runs the compiled binary against a real playbook (a real notified
# handler, not --check mode), since this bug is specifically about
# TaskExecutor#execute_handler_plugin_once, a private method not
# reachable from a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY        = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY     = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a template: task written as a handler (handlers/main.yml, not tasks/)" do
  it "runs the controller-side render step, matching what a regular template: task already gets" do
    # Real bug found benchmarking geerlingguy.jenkins: its own "configure
    # default users" handler is a template: task. #execute_task_once/
    # #prepare_batch_step (the two regular-task dispatch paths) both run
    # a task's module through ActionPluginManager first when one exists
    # (template:'s own action plugin reads/renders the .j2 file locally,
    # then injects the result as a `content:` param before the plugin
    # ever runs remotely) - #execute_handler_plugin_once, the SEPARATE
    # dispatch path used only for notified handlers, never did this at
    # all, so every template:/copy:-with-role-src:-style handler in a
    # real playbook failed outright with "Missing required parameter:
    # content" the instant it actually got notified and ran.
    src = File.tempname("template-handler-src", ".j2")
    dest = File.tempname("template-handler-dest")
    playbook = File.tempname("template-handler", ".yml")
    File.write(src, "value is {{ my_var }}\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          my_var: 42
        tasks:
          - name: trigger the handler
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: render via handler
        handlers:
          - name: render via handler
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should_not contain("Missing required parameter: content")
    File.read(dest).should eq("value is 42\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
