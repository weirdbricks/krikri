require "../spec_helper"

# Runs the compiled binary against a real playbook (a real notified
# handler, not --check mode), since this bug is specifically about
# TaskExecutor#notify_handlers / HandlerRunner#should_run_handler?,
# neither reachable from a unit spec without constructing a whole
# TaskExecutor + HandlerRunner pair.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("handler-notify-templating", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "notify: with a templated handler name" do
  it "fires a handler whose own name and notify: are both {{ }}-templated" do
    # task.notify was set once at parse time from raw YAML strings and
    # never re-substituted anywhere before being compared against the
    # loaded handler's own (also-templated) name - a templated notify:
    # never matched anything, so the handler silently never ran. Found
    # live via prometheus.prometheus.pushgateway's own `_common` role
    # (round 28's continuation): notify: "{{ ansible_parent_role_names
    # | first }} : Restart {{ _common_service_name }}" against a
    # handler named "Restart {{ _common_service_name }}".
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          service_name: "{{ 'my' ~ 'service' }}"
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: "Restart {{ service_name }}"
        handlers:
          - name: "Restart {{ service_name }}"
            ansible.builtin.debug:
              msg: "restarted {{ service_name }}"
      YAML

    status.success?.should be_true
    output.should contain("HANDLER [Restart myservice]")
    output.should contain("restarted myservice")
  end

  it "matches a role-qualified \"X : name\" notify: against the handler's own bare rendered name" do
    # Real Ansible auto-namespaces a role-loaded handler with a
    # qualifier prefix ("<role> : <handler name>") that isn't always
    # the role that literally defines handlers/main.yml (a nested
    # include_role case can qualify with the CALLING role's name
    # instead) - replicating the exact qualifier formula is real,
    # separate work. This covers the common case: any "X : name"
    # shaped notify string matches a handler by its own bare name,
    # regardless of what X is.
    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
            changed_when: true
            notify: "whatever.qualifier.value : restart thing"
        handlers:
          - name: restart thing
            ansible.builtin.debug:
              msg: "handler ran"
      YAML

    status.success?.should be_true
    output.should contain("handler ran")
  end
end
