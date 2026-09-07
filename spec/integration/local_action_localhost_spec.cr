require "../spec_helper"

# The legacy free-form `local_action: <module> [args]` directive (and the
# templated-module-name form of both `action:` and `local_action:`, e.g.
# jdauphant.intellij's `action: "{{ ansible_pkg_mgr }} state=present
# name={{ item }}"`) previously made the literal directive key the module
# name, so the task was skipped as an unimplemented plugin while real
# Ansible resolved and ran the real module. This covers the end-to-end
# path: parse-time rewrite, delegate-to-controller routing, and run-time
# module-name resolution all funneling into real module dispatch.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String) : {Process::Status, String}
  playbook = File.tempname("local-action", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "local_action: / templated action: end to end" do
  it "runs local_action: on the controller and registers its result" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: local echo
            local_action: ansible.builtin.command echo hi
            register: r
          - name: verify
            ansible.builtin.fail: msg="got {{ r.stdout }}"
            when: r.stdout != "hi"
      YAML
    status.success?.should be_true, output
    output.should contain("changed: [localhost]"), output
    output.should_not contain("unimplemented plugin"), output
    output.should_not contain("fatal:"), output
  end

  it "resolves a templated action: module name at run time" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          pkg: ansible.builtin.command
        tasks:
          - name: templated action
            action: "{{ pkg }} echo hello"
            register: r
          - name: verify
            ansible.builtin.fail: msg="got {{ r.stdout }}"
            when: r.stdout != "hello"
      YAML
    status.success?.should be_true, output
    output.should contain("changed: [localhost]"), output
    output.should_not contain("fatal:"), output
  end

  it "resolves a templated local_action: module name at run time on the controller" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          pkg: ansible.builtin.command
        tasks:
          - name: templated local_action
            local_action: "{{ pkg }} echo controller"
            register: r
          - name: verify
            ansible.builtin.fail: msg="got {{ r.stdout }}"
            when: r.stdout != "controller"
      YAML
    status.success?.should be_true, output
    output.should contain("changed: [localhost]"), output
    output.should_not contain("fatal:"), output
  end

  it "fails the task cleanly when a templated action: name resolves to nothing" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          pkg: no_such_module_ansible
        tasks:
          - name: bogus templated action
            action: "{{ pkg }} key=value"
      YAML
    status.success?.should be_false, output
    output.should contain("couldn't resolve module/action 'no_such_module_ansible'"), output
  end
end
