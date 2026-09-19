require "../spec_helper"
require "file_utils"

# The UnresolvedModuleError hard-stop, end to end. A tombstoned-removed
# module name like `ec2_remote_facts` - one real Ansible ITSELF refuses
# to resolve anywhere, at its own playbook-load time - must refuse to
# run the playbook AT ALL, rc=4, no PLAY RECAP, nothing executes,
# matching real Ansible's own playbook-load module-resolution check
# (verified live against ansible-core 2.19.4, including the when:-gated
# variant: the resolution check is a playbook-LOAD check there, not a
# per-task one).
#
# A plain "krikri simply hasn't implemented this" module is DIFFERENT
# (0.9.1050, reversing 0.9.903's unconditional hard-stop, round 811000):
# real Ansible resolves a task's module lazily, per task, only once the
# task is actually about to run - after its own `when:` evaluated true -
# so krikri must not abort the whole load at parse time for a task that
# would never run. The task parses through with unavailable_module set
# and takes the graceful runtime skip path; the safety net is that
# reachable_unavailable_modules records the module name if its own
# `when:` would have let it run for at least one host at RUNTIME (after
# facts are gathered), and the run still exit(4)s at the very end - a
# genuinely-reached unimplemented module is never silently swallowed.
# Round 811000 found the old parse-time hard-stop aborting 25 real
# roles outright for when:-gated modules: robertdebock.podman
# (containers.podman.podman_container behind `when: podman_containers is
# defined`, false on the role's own defaults - real Ansible ok=7
# changed=2, krikri rc=4 with zero tasks run), mashimom.oh-my-zsh (apk:
# behind `when: ansible_pkg_mgr == 'apk'` on a Debian host - real
# Ansible's only failure was a later, unrelated one), and ~23 more of
# the same shape (Windows-only modules, OS-family branches, feature-flag
# definedness checks).
#
# The ONLY module resolving to nothing krikri ships that RUNS is a
# role-private `library/<name>.py` (or playbook-adjacent `library/`)
# source, executed via PythonModuleRunner - that's not "unimplemented",
# it's a real module this engine executes.
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

  it "runs to completion when a when:-gated unimplemented module's gate is false" do
    # kubernetes.core is a real, commonly-installed collection real
    # ansible-playbook would resolve and run fine here - krikri simply
    # hasn't ported this specific module. Round 811000: the module name
    # must be resolved lazily like real Ansible does (only once the
    # task is about to run, after its when: evaluates), so a gate that
    # is false on this host (`ansible_os_family == "Windows"` on a
    # Linux-family run) means the task is cleanly skipped and the rest
    # of the play runs to a green recap - the old parse-time hard-stop
    # aborted the whole load before a single task executed.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: normal
            ansible.builtin.debug: msg=hi
          - name: unported collection, when-gated - cleanly skipped
            kubernetes.core.helm_repository:
              repo_name: foo
            when: ansible_os_family == "Windows"
      YAML
    status.success?.should be_true, output
    output.should contain("PLAY RECAP"), output
    output.should contain("TASK [normal]"), output
    output.should contain("skipping: [localhost]"), output
    output.should_not contain("unavailable modules"), output
  end

  it "exit-4s at the END of the run for a genuinely-reached unimplemented module, after a full recap" do
    # The inverse, safety side of the reversal: with NO when: gate the
    # task is genuinely reached, so the run still fails - but now via
    # the runtime reachable_unavailable_modules machinery (exit 4 after
    # the recap, from krikri-playbook.cr's end-of-run check) rather
    # than a parse-time abort, so the other tasks in the play actually
    # ran and show in the PLAY RECAP - matching real Ansible's own
    # per-task resolution timing.
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
    status.exit_code.should eq(4), output
    output.should contain("✗ Playbook execution completed with unavailable modules: ansible.builtin.sysvinit"), output
    output.should contain("PLAY RECAP"), output
    output.should contain("TASK [normal]"), output
  end

  it "exit-4s for a FIRED handler backed by an unimplemented module, but never fires one behind an unchanged notify" do
    # juju4.falco's own shape: kubernetes.core.helm_repository as a
    # notified handler. A handler only runs when a task that reported
    # CHANGED notifies it (real Ansible: an ok/skipped task notifies
    # nothing), so the fired case is genuinely reached and exit-4s at
    # the end of the run via reachable_unavailable_modules - while an
    # unchanged notify (the debug task below) leaves the handler
    # unfired and the run green, exactly like real Ansible.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: changed task that notifies the handler
            ansible.builtin.command: "true"
            notify: unported handler
        handlers:
          - name: unported handler
            kubernetes.core.helm_repository:
              repo_name: foo
      YAML
    status.success?.should be_false, output
    status.exit_code.should eq(4), output
    output.should contain("HANDLER [unported handler]"), output
    output.should contain("✗ Playbook execution completed with unavailable modules: kubernetes.core.helm_repository"), output
    output.should contain("PLAY RECAP"), output

    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: unchanged task that notifies the handler
            ansible.builtin.debug: msg=hi
            notify: unported handler
        handlers:
          - name: unported handler
            kubernetes.core.helm_repository:
              repo_name: foo
      YAML
    status.success?.should be_true, output
    output.should contain("PLAY RECAP"), output
    output.should_not contain("unported handler"), output
  end

  it "runs an unrelated LATER task after a when:-gated unimplemented one (round 811000, robertdebock.podman's shape)" do
    # The exact real-world shape that motivated the reversal: an
    # earlier task, then a when:-gated task using an unimplemented
    # module whose gate is false (podman_containers left undefined -
    # robertdebock.podman's own defaults), then a later unrelated task.
    # Real ansible-playbook: all three run/skip cleanly, green recap.
    # The old parse-time hard-stop killed the whole play before the
    # first task; the fixed engine must run the earlier task, skip the
    # gated one, and still execute the later one.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: earlier unrelated task
            ansible.builtin.debug: msg=before
          - name: manage podman containers (unimplemented module, false gate)
            containers.podman.podman_container:
              name: foo
            when: podman_containers is defined and podman_containers | length > 0
          - name: later unrelated task
            ansible.builtin.debug: msg=after
      YAML
    status.success?.should be_true, output
    output.should contain("TASK [earlier unrelated task]"), output
    output.should contain("TASK [manage podman containers (unimplemented module, false gate)]"), output
    output.should contain("TASK [later unrelated task]"), output
    output.should contain("PLAY RECAP"), output
    output.should_not contain("unavailable modules"), output
  end

  it "still exit-4s when the gate on the unimplemented module evaluates TRUE (never silently swallow a reached module)" do
    # Same shape with the gate TRUE: the module really would run, so
    # the run must still fail - exit 4 from the end-of-run
    # unavailable-modules check, with the play's tasks and recap
    # showing first (real Ansible would fail the task itself mid-run).
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          podman_containers:
            - name: foo
        tasks:
          - name: earlier unrelated task
            ansible.builtin.debug: msg=before
          - name: manage podman containers (unimplemented module, true gate)
            containers.podman.podman_container:
              name: foo
            when: podman_containers is defined and podman_containers | length > 0
      YAML
    status.success?.should be_false, output
    status.exit_code.should eq(4), output
    output.should contain("✗ Playbook execution completed with unavailable modules: containers.podman.podman_container"), output
    output.should contain("TASK [earlier unrelated task]"), output
    output.should contain("PLAY RECAP"), output
  end

  it "still runs a role-private library/*.py module (the one exception - genuinely runs here, not unimplemented)" do
    root = File.tempname("role-private-module-still-runs")
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "library"))
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "tasks"))
    File.write(File.join(root, "roles", "reprorole", "library", "reprofilter.py"), <<-PYTHON)
      #!/usr/bin/python
      print('{"changed": true, "msg": "ran"}')
      PYTHON
    File.write(File.join(root, "roles", "reprorole", "tasks", "main.yml"), <<-YAML)
      - name: dispatch a role-private python module
        reprofilter:
          name: x
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - reprorole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.should be_true, output.to_s
    output.to_s.should contain("PLAY RECAP"), output.to_s
    output.to_s.should_not contain("krikri does not yet have module"), output.to_s
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "fails the task fatally when the unimplemented module's own when: raises (undefined var), instead of silently skipping" do
    # Real Ansible evaluates a non-looped task's `when:` BEFORE it ever
    # attempts module resolution - so a when: referencing a genuinely
    # undefined variable is a fatal conditional error (rc=2, failed=1,
    # "Error while evaluating conditional: '...' is undefined") even
    # when that same task's module is ALSO unresolvable (verified live
    # against ansible-core 2.19.11 with junipernetworks.junos.junos_netconf).
    # Round 900000-900999 (lukapetrovic-git.azure_ad_app,
    # CyVerse-Ansible.rabbitmq_vhost): the old code short-circuited an
    # unavailable-module task straight to "skipping" without evaluating
    # when: at all, turning that real fatal into a silent rc=0 skip.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: unresolvable module, undefined var in when
            junipernetworks.junos.junos_netconf:
            when: some_genuinely_undefined_var == 'x'
      YAML
    status.success?.should be_false, output
    status.exit_code.should eq(2), output
    output.should contain("Error while evaluating conditional: 'some_genuinely_undefined_var' is undefined"), output
    output.should contain("failed=1"), output
    output.should_not contain("skipping: [localhost]"), output
  end

  it "still cleanly skips an unimplemented module behind a literal `when: false`" do
    # The inverse guard on the same code path: real Ansible checks when:
    # FIRST, and a false condition means module resolution is never even
    # attempted - so unavailable-module + when:-false remains a plain
    # rc=0 skip (verified live against ansible-core 2.19.11), never a
    # newly-fatal task and never an unavailable-modules exit 4.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: unresolvable module, when false
            junipernetworks.junos.junos_netconf:
            when: false
      YAML
    status.success?.should be_true, output
    output.should contain("skipping: [localhost]"), output
    output.should contain("PLAY RECAP"), output
    output.should_not contain("unavailable modules"), output
  end
end
