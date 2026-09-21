require "../spec_helper"
require "file_utils"

# Real bug found against the dirless-infra workspace (2026-09-20,
# krikri-vs-ansible findings Bug 5): the inventory lives in a SUBDIR
# (ansible/inventory/backend_hosts.yml) while group_vars/ sits beside
# the playbooks (ansible/group_vars/backend_nodes.yml) - the standard
# Ansible layout. This engine only ever loaded group_vars/host_vars
# from the INVENTORY's directory, so a plain static var like
# ops_probe_pubkey read as undefined in play 2 (`hosts: backend_nodes`)
# and failed the play - only when the inventory was not adjacent to the
# playbooks, which is why every `connection: local` minimal repro with
# the files beside each other passed. Real Ansible loads BOTH trees
# (live-verified against ansible-core 2.19.11): a same-key conflict
# resolves to the PLAYBOOK side, and inline inventory host vars still
# outrank every vars file.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "group_vars/host_vars loaded from the playbook directory too" do
  it "resolves a playbook-adjacent group_vars var for an inventory in a subdir" do
    workspace = File.tempname("pb-adjacent-vars", ".d")
    Dir.mkdir_p(File.join(workspace, "inventory", "group_vars", "mygroup"))
    Dir.mkdir_p(File.join(workspace, "group_vars", "mygroup"))
    Dir.mkdir_p(File.join(workspace, "inventory", "host_vars"))

    # Inventory in a SUBDIR (the dirless-infra shape), playbook-adjacent
    # group_vars carrying the var the play needs.
    File.write(File.join(workspace, "inventory", "hosts.yml"), <<-YAML)
      all:
        children:
          mygroup:
            hosts:
              web1:
                ansible_connection: local
      YAML
    File.write(File.join(workspace, "group_vars", "mygroup.yml"), "probe_var: \"FROM-PLAYBOOK\"\n")

    playbook = File.join(workspace, "play.yml")
    File.write(playbook, <<-YAML)
      - name: probe
        hosts: mygroup
        gather_facts: false
        tasks:
          - name: show
            ansible.builtin.debug:
              var: probe_var
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(workspace, "inventory", "hosts.yml"), playbook, "--check"], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("FROM-PLAYBOOK")
    output.to_s.should_not contain("VARIABLE IS NOT DEFINED")
  ensure
    FileUtils.rm_rf(workspace) if workspace
  end

  it "prefers the playbook side on a same-key conflict, without touching inline host vars" do
    workspace = File.tempname("pb-adjacent-precedence", ".d")
    Dir.mkdir_p(File.join(workspace, "inventory", "group_vars"))
    Dir.mkdir_p(File.join(workspace, "group_vars"))

    File.write(File.join(workspace, "inventory", "hosts.yml"), <<-YAML)
      all:
        children:
          mygroup:
            hosts:
              web1:
                ansible_connection: local
                probe_var: "INLINE-WINS"
      YAML
    File.write(File.join(workspace, "inventory", "group_vars", "mygroup.yml"), "probe_var: \"FROM-INVENTORY\"\ninv_only: \"INV-ONLY\"\n")
    File.write(File.join(workspace, "group_vars", "mygroup.yml"), "probe_var: \"FROM-PLAYBOOK\"\npb_only: \"PB-ONLY\"\n")

    playbook = File.join(workspace, "play.yml")
    File.write(playbook, <<-YAML)
      - name: probe
        hosts: mygroup
        gather_facts: false
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: "probe={{ probe_var }} inv={{ inv_only | default('U') }} pb={{ pb_only | default('U') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(workspace, "inventory", "hosts.yml"), playbook, "--check"], output: output, error: output)

    rendered = output.to_s
    status.success?.should be_true
    rendered.should contain("probe=INLINE-WINS")
    rendered.should contain("inv=INV-ONLY")
    rendered.should contain("pb=PB-ONLY")
  ensure
    FileUtils.rm_rf(workspace) if workspace
  end
end
