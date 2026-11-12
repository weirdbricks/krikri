require "../minitest_helper"
require "../../src/krikri/plugin_helpers/python_lib_gate"

# An unported `k8s` reference (kubernetes.core.k8s - real roles
# overwhelmingly write the bare short name) runs a synthesized import gate
# on the target instead of the unavailable-module skip: the module family
# imports the `kubernetes` client library at MODULE level, so on a target
# without it real ansible fails the task with basic.py's
# missing_required_lib text before the module ever validates an argument
# or touches a cluster (live-verified vs ansible-core 2.21.6 with
# ansible_connection=local, thoth-station.external_janusgraph_service,
# issue #1155) - a failed task (rc=2), never the failed=0/exit-4 skip.
# Real runs the module under --check too (the family supports check
# mode), so the check-mode run - what krikri-role-tester compares - fails
# the same way. The gate reports a sentinel when the library IS
# importable: the module would then go on to talk to a cluster this
# engine cannot emulate, so the designed unavailable-module skip applies.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def kubernetes_importable? : Bool
  Krikri.missing_python_library("kubernetes", "kubernetes").nil?
end

private def run_playbook(yaml : String, check : Bool = false, extra_env : Hash(String, String) = {} of String => String) : {Process::Status, String}
  playbook = File.tempname("k8s-import-gate", ".yml")
  File.write(playbook, yaml)
  args = ["-i", INVENTORY]
  args << "--check" if check
  args << playbook
  output = IO::Memory.new
  status = Process.run(BINARY, args, output: output, error: output,
    env: ENV.to_h.merge(extra_env))
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private TWO_K8S_TASK_PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: create a k8s object
        k8s:
          state: present
          definition:
            apiVersion: v1
            kind: Service
            metadata:
              name: janusgraph
      - name: create another k8s object
        k8s:
          state: present
          definition:
            apiVersion: v1
            kind: Endpoints
            metadata:
              name: janusgraph
  YAML

describe "unported k8s module import gate" do
  it "fails the task with the missing-library error instead of skipping under --check" do
    skip "python on this host can import kubernetes" if kubernetes_importable?

    status, output = run_playbook(TWO_K8S_TASK_PLAYBOOK, check: true)

    # Real's own exit for a failed task (2), not the engine-limit exit 4
    # the unavailable-module skip produces.
    status.exit_code.must_equal(2)
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Failed to import the required Python library (kubernetes) on ")
    # The message names the interpreter the module would run under - the
    # same discovery real's basic.py embeds.
    interp = output.match(/Failed to import the required Python library \(kubernetes\) on \S+'s Python (\S+)\./).try(&.[1])
    flunk output if interp.nil?
    interp.must_equal(Krikri.discovered_target_python)
    output.must_include("[ERROR]: Task failed: Module failed: Failed to import the required Python library (kubernetes)")
    output.must_include("Origin:")
    output.must_include("failed=1")
    output.wont_include("skipped=1")
    # A failed task halts the host, so the second k8s task never shows a
    # banner (real never reaches it either).
    output.wont_include("create another k8s object")
    # The engine-limit warning and its exit-4 accounting stay out: the
    # task failed like a module failure, it was not "unavailable".
    output.wont_include("uses unimplemented plugin")
  end

  it "fails the same way outside check mode" do
    skip "python on this host can import kubernetes" if kubernetes_importable?

    status, output = run_playbook(TWO_K8S_TASK_PLAYBOOK)

    status.exit_code.must_equal(2)
    output.must_include("Failed to import the required Python library (kubernetes) on ")
    output.must_include("failed=1")
    output.wont_include("skipped=1")
  end

  it "gates the kubernetes.core.k8s FQCN spelling too" do
    skip "python on this host can import kubernetes" if kubernetes_importable?

    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: fqcn k8s object
            kubernetes.core.k8s:
              state: present
              definition:
                apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: cm
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Failed to import the required Python library (kubernetes) on ")
    output.must_include("failed=1")
    output.wont_include("uses unimplemented plugin")
  end

  it "lets ignore_errors continue the play" do
    skip "python on this host can import kubernetes" if kubernetes_importable?

    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: ignorable k8s failure
            k8s:
              state: present
              definition:
                apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: cm
            ignore_errors: true
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(0)
    output.must_include("Failed to import the required Python library (kubernetes) on ")
    output.must_include("...ignoring")
    output.must_include("SHOULD-RUN-AFTER")
    output.must_include("ignored=1")
    output.wont_include("failed=1")
  end

  it "still skips a k8s task whose when: is false" do
    # A when:-false task never reaches module resolution in real either,
    # so the normal skip still applies (and the gate never runs).
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: false when on k8s
            k8s:
              state: present
              definition:
                apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: cm
            when: false
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(0)
    output.must_include("skipped=1")
    output.wont_include("failed=1")
    output.must_include("SHOULD-RUN-AFTER")
  end

  it "falls back to the unavailable-module skip when the library is importable" do
    # A stub `kubernetes` package on PYTHONPATH makes the gate's import
    # succeed; the module would then go on to talk to a cluster, which
    # this engine does not implement - so the designed unavailable-module
    # skip (and its exit-4 accounting) applies, as before the gate.
    fake_lib = PluginSpecHelper.tmp_path("k8s-gate-fake-lib")
    FileUtils.mkdir_p(fake_lib)
    File.write(File.join(fake_lib, "kubernetes.py"), "# stub: import succeeds\n")

    status, output = run_playbook(TWO_K8S_TASK_PLAYBOOK,
      extra_env: {"PYTHONPATH" => fake_lib})

    status.exit_code.must_equal(4)
    output.must_include("uses unimplemented plugin: k8s")
    output.must_include("skipped=2")
    output.wont_include("Failed to import the required Python library")
  end

  it "still runs a role-private library/k8s.py instead of the gate" do
    # A role shipping its own k8s module keeps the arbitrary-Python-module
    # path: the gate only fires for a name with NO resolvable source.
    root = PluginSpecHelper.tmp_path("k8s-gate-role-library")
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "library"))
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "tasks"))
    File.write(File.join(root, "roles", "reprorole", "library", "k8s.py"), <<-PYTHON)
      #!/usr/bin/python
      print('{"changed": true, "msg": "ROLE-PRIVATE-K8S-RAN"}')
      PYTHON
    File.write(File.join(root, "roles", "reprorole", "tasks", "main.yml"), <<-YAML)
      - name: role-private k8s module
        k8s:
          state: present
      YAML
    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - reprorole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output,
      error: output, chdir: root)

    status.exit_code.must_equal(0)
    # The module actually ran (changed: line) - not the gate's failure and
    # not the unavailable-module skip (which would print "skipping:").
    output.to_s.must_include("changed: [localhost]")
    output.to_s.wont_include("Failed to import the required Python library")
    output.to_s.wont_include("skipping: [localhost]")
    output.to_s.wont_include("uses unimplemented plugin")
  end
end
