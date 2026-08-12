require "../spec_helper"

# Runs the compiled binary against a real playbook (a real notified
# handler, not --check mode), since this bug is specifically about
# TaskExecutor#execute_handler_plugin_once, a private method not
# reachable from a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY        = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY     = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a handler's own register:/changed_when:/failed_when:" do
  it "applies register:, making the handler's own result visible to a later listener" do
    # Real bug found benchmarking geerlingguy.gitlab: #execute_handler_
    # plugin_once (the SEPARATE dispatch path used only for notified
    # handlers, same one template_handler_spec.cr's own bug lived in)
    # returned the raw plugin result directly - a handler's own
    # register: was silently never stored at all, so anything
    # downstream referencing it (another task, another handler via
    # listen:) always saw undefined.
    playbook = File.tempname("handler-register", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger the handler
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: produce a result
        handlers:
          - name: produce a result
            ansible.builtin.command: echo handler-output
            register: handler_result
          - name: use the result
            ansible.builtin.debug:
              msg: "got:{{ handler_result.stdout | default('MISSING') }}"
            listen: produce a result
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("got:handler-output")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "applies failed_when:, overriding the handler's own default failure" do
    # Same missing step, different symptom: geerlingguy.gitlab's own
    # "restart gitlab" handler (`command: gitlab-ctl reconfigure`,
    # `failed_when: gitlab_restart_handler_failed_when | bool`) expects
    # a real (and, for a known upstream GitLab/role-version
    # incompatibility, EXPECTED) nonzero exit to be suppressed - real
    # ansible-playbook's own run of the identical role reports this
    # handler as "changed", not failed. Previously always failed
    # outright here since failed_when: could never be applied.
    playbook = File.tempname("handler-failed-when", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger the handler
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: might fail
        handlers:
          - name: might fail
            ansible.builtin.command: /bin/false
            failed_when: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should_not contain("failed=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
