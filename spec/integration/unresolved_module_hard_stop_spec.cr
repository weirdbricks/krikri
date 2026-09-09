require "../spec_helper"

# The UnresolvedModuleError hard-stop, end to end: a task whose module
# name real ansible-core can't resolve ANYWHERE - a tombstoned-removed
# module like `ec2_remote_facts` - must refuse to run the playbook AT
# ALL, printing real Ansible's "[ERROR]: couldn't resolve module/action
# '...'" (rc=4, no PLAY RECAP, nothing executes) - verified live
# against ansible-core 2.19.4, including the when:-gated variant.
# Previously this engine took the graceful per-task unavailable_module
# skip for that shape too, kept executing every other task, and hit
# unrelated downstream failures that masked the divergence shape
# entirely (Aplyca.EC2Describe, round71000). 0.9.860 also hard-stopped
# FQCNs from collections with zero krikri modules; 0.9.861 narrowed
# that back (real unported collections like kubernetes.core broke), so
# the later specs pin the graceful-skip half of the restored boundary.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String) : {Process::Status, String}
  playbook = File.tempname("unresolved-module", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "unresolvable module names hard-stop the run (UnresolvedModuleError)" do
  it "aborts before any task runs for a bare module removed from ansible-core (ec2_remote_facts)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: removed module
            ec2_remote_facts:
          - name: normal
            ansible.builtin.debug: msg=hi
      YAML
    status.success?.should be_false, output
    output.should contain("[ERROR]: couldn't resolve module/action 'ec2_remote_facts'"), output
    output.should_not contain("PLAY RECAP"), output
    output.should_not contain("TASK ["), output
    output.should_not contain("Gathering Facts"), output
  end

  it "runs to completion for a module from a collection with zero krikri modules (graceful skip, no hard-stop)" do
    # 0.9.861 restored this shape to the graceful skip: kubernetes.core
    # is a real, commonly-installed collection krikri simply hasn't
    # ported anything from - the 0.9.860 "zero modules = never
    # installed" heuristic hard-stopped exactly such roles (live round
    # repro) that real ansible-playbook runs fine. A when:-gated
    # bodsch.scm FQCN (the original round71000 role's shape) keeps the
    # same graceful path - its downstream "No filter named 'bodsch'"
    # masking risk is the accepted residual gap now.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: normal
            ansible.builtin.debug: msg=hi
          - name: unported collection, when-gated like the real role's usage
            kubernetes.core.helm_repository:
              repo_name: foo
            when: ansible_os_family == "Windows"
      YAML
    status.success?.should be_true, output
    output.should contain("PLAY RECAP"), output
    output.should contain("skipping: [localhost]"), output
    output.should contain("uses unimplemented plugin: kubernetes.core.helm_repository"), output
    output.should_not contain("[ERROR]: couldn't resolve module/action"), output
  end

  it "still gracefully skips a not-yet-implemented module from a RECOGNIZED collection, exactly as before" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: unimplemented builtin
            ansible.builtin.sysvinit:
              name: foo
          - name: normal
            ansible.builtin.debug: msg=hi
      YAML
    status.success?.should be_false, output
    # The unimplemented task is skipped with a warning, not fatal; the
    # rest of the play runs to completion and prints a recap.
    output.should contain("skipping: [localhost]"), output
    output.should contain("uses unimplemented plugin: ansible.builtin.sysvinit"), output
    output.should contain("PLAY RECAP"), output
    output.should_not contain("[ERROR]: couldn't resolve module/action"), output
  end
end
