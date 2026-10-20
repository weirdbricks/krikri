require "../minitest_helper"

# community.routeros.command / community.routeros.facts are network modules:
# they run through the persistent network_cli/httpapi socket that only a
# network connection plugin provides. On an ordinary local/ssh host real
# ansible does NOT silently skip them (the old unavailable-module skip gave
# failed=0 / exit 4) - the module attempts to run and fails immediately with
# "socket_path must be a value" (live-verified vs 2.19.11 with
# ansible_connection=local): failed=1, exit 2, the [ERROR]: Task failed:
# Module failed: block with the task's Origin, and the play stops at the
# failing task unless ignore_errors: is set.
#
# Like unavailable_module_args_finalization_test.cr, the specs pin the flow
# against a CONTROLLED controller: ANSIBLE_COLLECTIONS_PATH points at a
# fixture tree whose community.routeros ships module stub files, so the
# controller-resolves check passes and the engine takes its lazy
# unavailable-module path - identically whether or not the test machine has
# community.routeros installed.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("routeros-network-only", ".yml")
  File.write(playbook, yaml)
  fixture_root = File.tempname("routeros-collections")
  module_dir = File.join(fixture_root, "ansible_collections", "community", "routeros", "plugins", "modules")
  FileUtils.mkdir_p(module_dir)
  File.write(File.join(module_dir, "routeros_command.py"), "#!/usr/bin/python\n")
  File.write(File.join(module_dir, "routeros_facts.py"), "#!/usr/bin/python\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
    env: {"ANSIBLE_COLLECTIONS_PATH" => fixture_root})
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  FileUtils.rm_r(fixture_root) if fixture_root && Dir.exists?(fixture_root)
end

describe "network-only unavailable module on local connection" do
  it "fails the task with the socket_path error instead of skipping" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: routeros on a local host
            community.routeros.command: /system resource print
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    # Real's own exit for a failed task (2), not the engine-limit exit 4
    # the unavailable-module skip produces.
    status.exit_code.must_equal(2)
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Module failed: socket_path must be a value"}))
    output.must_include("[ERROR]: Task failed: Module failed: socket_path must be a value")
    output.must_include("Origin:")
    output.must_include("failed=1")
    output.wont_include("skipped=1")
    # A failed task halts the host, so the sentinel task never runs.
    output.wont_include("SHOULD-RUN-AFTER")
  end

  it "fails the same way for the short routeros_command spelling" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: routeros short spelling
            routeros_command: /system resource print
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Task failed: Module failed: socket_path must be a value")
    output.must_include("failed=1")
    output.wont_include("SHOULD-RUN-AFTER")
  end

  it "lets ignore_errors continue the play" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: routeros failure is ignorable
            community.routeros.command: /system resource print
            ignore_errors: true
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(0)
    output.must_include("Task failed: Module failed: socket_path must be a value")
    output.must_include("...ignoring")
    output.must_include("SHOULD-RUN-AFTER")
    output.must_include("ignored=1")
    output.wont_include("failed=1")
  end

  it "still skips routeros_facts when its when: is false" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: false when on routeros facts
            community.routeros.facts:
              gather_subset: all
            when: false
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    # A when:-false task never reaches module resolution in real either,
    # so the normal skip still applies.
    status.exit_code.must_equal(0)
    output.must_include("skipped=1")
    output.wont_include("failed=1")
    output.must_include("SHOULD-RUN-AFTER")
  end
end
