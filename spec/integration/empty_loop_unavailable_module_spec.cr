require "../spec_helper"
require "file_utils"

# An unimplemented module behind a task whose loop resolves to ZERO items
# is a plain skip, never an exit-4 "unavailable modules" report. Real
# Ansible resolves a looped task's module per-item inside
# _execute_internal, so with zero items the module name is never resolved
# (live-verified against ansible-core 2.19.11: looped missing-module task
# over an empty list prints "skipping:", rc=0). The old 0.9.692 behavior
# - registering the module at the empty-loop site "regardless of loop
# emptiness" - drove a bogus rc=4 on an otherwise-green run: found via
# telekom_mms.grafana, whose grafana_datasource/grafana_folder/grafana_
# team/grafana_user/grafana_dashboard tasks all loop over empty role
# defaults (real Ansible: skipped=5, rc=0; krikri rc=4 "completed with
# unavailable modules").
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String) : {Process::Status, String}
  playbook = File.tempname("empty-loop-unavailable", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "an unimplemented module behind an empty loop is a plain skip, rc=0" do
  it "runs green when the loop list is empty via a role default" do
    root = File.tempname("empty-loop-unavailable-role")
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "tasks"))
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "defaults"))
    File.write(File.join(root, "roles", "reprorole", "defaults", "main.yml"),
      "grafana_datasources: []\n")
    File.write(File.join(root, "roles", "reprorole", "tasks", "main.yml"), <<-YAML)
      - name: Manage datasource
        community.grafana.grafana_datasource:
          name: x
        loop: "{{ grafana_datasources }}"
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - reprorole
        tasks:
          - name: later unrelated task
            ansible.builtin.debug:
              msg: after
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.should be_true, output.to_s
    output.to_s.should contain("skipping:"), output.to_s
    output.to_s.should contain("PLAY RECAP"), output.to_s
    output.to_s.should contain("TASK [later unrelated task]"), output.to_s
    output.to_s.should_not contain("unavailable modules"), output.to_s
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "still reports a genuinely-reached unimplemented module on a NON-empty loop" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          items: [one]
        tasks:
          - name: unimplemented module with an item
            community.grafana.grafana_datasource:
              name: x
            loop: "{{ items }}"
      YAML
    status.success?.should be_false, output
    status.exit_code.should eq(4), output
    output.should contain("unavailable modules: community.grafana.grafana_datasource"), output
    output.should contain("PLAY RECAP"), output
  end

  it "still reports an unimplemented module without a loop (the solo-path safety net is untouched)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: unimplemented module, no loop
            community.grafana.grafana_datasource:
              name: x
      YAML
    status.success?.should be_false, output
    status.exit_code.should eq(4), output
    output.should contain("unavailable modules: community.grafana.grafana_datasource"), output
  end
end
