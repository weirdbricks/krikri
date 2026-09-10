require "../spec_helper"

# Runs the compiled binary. The batched loop path (execute_looped_task_
# batched) is only reachable for a NON-local host (loop_batch_eligible?
# excludes local connections), so this uses the inventory-nonlocal-host.ini
# fixture - safe because a looped debug: computes its whole result on the
# controller (action-plugin final_result) and never opens an SSH connection.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-nonlocal-host.ini")

describe "a looped task whose own vars: reference item (batched loop path)" do
  # aisbergg.beats round 90007 (Ubuntu 22.04): `install Beats (Debian)` has
  # `vars: { state: "{{ lookup('vars', item ~ '_install_state') }}" }` and
  # loop_control.label referencing `state`. build_vars_context rendered the
  # vars: ONCE before `item` was bound, the raise-to-absent rescue deleted
  # `state` from the base context, and the batched path (unlike the
  # one-at-a-time path, which already restored + re-rendered task.vars per
  # item) never re-applied it - every item failed with "'state' is
  # undefined" where real ansible-core ran all six apt iterations
  # successfully. loop_control.label also rendered "undefined <item>"
  # against the stripped base context on BOTH paths; real Ansible shows the
  # resolved label ("uninstall auditbeat").
  it "resolves task vars per item instead of failing with '<var>' is undefined" do
    playbook = File.tempname("loop-task-vars-item", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: batchhost
        gather_facts: false
        vars:
          a_state: absent
          b_state: present
          c_state: absent
        tasks:
          - name: loop with task var referencing item
            ansible.builtin.debug:
              msg: "state={{ state }} item={{ item }}"
            loop: [a, b, c]
            vars:
              state: "{{ lookup('vars', item ~ '_state') }}"
            loop_control:
              label: "{{ state }} {{ item }}"
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    out = output.to_s
    out.should contain("state=absent item=a")
    out.should contain("state=present item=b")
    out.should contain("state=absent item=c")
    out.should contain("failed=0")
    out.should_not contain("'state' is undefined")
    # loop_control.label sees the per-item task var too (real Ansible's
    # display), not the literal "undefined" fallback.
    out.should contain("(item=absent a)")
    out.should_not contain("item=undefined")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # The one-at-a-time path had this fixed earlier (linux-system-roles/
  # kernel_settings) - this only pins that --no-batching still resolves the
  # same playbook correctly, so the two transports agree.
  it "also resolves per item on the non-batched path" do
    playbook = File.tempname("loop-task-vars-item-nobatch", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: batchhost
        gather_facts: false
        vars:
          a_state: absent
          b_state: present
          c_state: absent
        tasks:
          - name: loop with task var referencing item
            ansible.builtin.debug:
              msg: "state={{ state }} item={{ item }}"
            loop: [a, b, c]
            vars:
              state: "{{ lookup('vars', item ~ '_state') }}"
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "--no-batching", playbook], output: output, error: output)

    out = output.to_s
    out.should contain("state=absent item=a")
    out.should contain("state=present item=b")
    out.should contain("failed=0")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
