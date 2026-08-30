require "../spec_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "ansible_ssh_user/ansible_ssh_host/ansible_ssh_port legacy aliases" do
  it "resolves the deprecated ansible_ssh_* spelling to whatever the canonical ansible_* var holds" do
    # Real bug found benchmarking round168's geerlingguy.phergie on
    # Ubuntu 22.04: `defaults/main.yml` sets `phergie_user: "{{
    # ansible_ssh_user }}"` (real Ansible's variable manager treats
    # ansible_ssh_user as a deprecated-but-still-honored alias of
    # ansible_user) - this engine only ever populated the canonical
    # ansible_user spelling (naturally, since that's the literal
    # inventory var name in the common case), so ansible_ssh_user
    # resolved to nothing, rendering the literal "undefined" text
    # wherever a role's own default referenced it - here, `file: {owner:
    # "{{ phergie_user }}"}` failed with "chown failed: failed to look
    # up user undefined".
    inventory = File.tempname("ansible-ssh-user-inv", ".ini")
    File.write(inventory, "node ansible_connection=local ansible_user=root\n")

    playbook = File.tempname("ansible-ssh-user", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: all
        gather_facts: false
        tasks:
          - name: show it
            ansible.builtin.debug:
              msg: "ansible_user={{ ansible_user }} ansible_ssh_user={{ ansible_ssh_user }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
    status.success?.should be_true
    output.to_s.should contain("ansible_user=root ansible_ssh_user=root")
    output.to_s.should_not contain("is undefined")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
