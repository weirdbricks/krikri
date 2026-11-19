require "../minitest_helper"
require "../../src/krikri/plugin_helpers/python_lib_gate"

# community.vmware's modules are not ported, but real ansible still runs
# them: the collection's module_utils imports (and its PyVmomi class
# requires) `requests` and `PyVmomi`, and every module in the family
# declares supports_check_mode=True, so on a target without those
# libraries ansible-playbook - under --check too - fails the task with
# basic.py's missing_required_lib text instead of skipping it
# (jedimt.vmware_vcsa_customization, issue #1523: real failed its first
# task, krikri skipped two and then departed at a later task's own
# templating fatal, exit 4 against real's 2). This engine therefore runs
# the synthesized gate in PythonModuleRunner.vmware_import_gate_source,
# which reproduces the failure and the deprecated module_utils imports'
# [DEPRECATION WARNING] lines; real's five load-time collection
# deprecation blocks (community.vmware's meta/runtime.yml
# plugin_routing.modules entries) print from the parser for a task that
# is never reached, the same as real.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def vmware_gate_skips? : Bool
  Krikri.missing_python_library("requests", "requests").nil? &&
    Krikri.missing_python_library("PyVmomi", "pyVmomi").nil?
end

# The library the gate reports missing on THIS host, in the gate's own
# order (requests before PyVmomi).
private def missing_vmware_library : String
  Krikri.missing_python_library("requests", "requests") ? "requests" : "PyVmomi"
end

private def run_vmware_playbook(yaml : String, check : Bool = false) : {Process::Status, String, String}
  playbook = File.tempname("vmware-import-gate", ".yml")
  File.write(playbook, yaml)
  args = ["-i", INVENTORY]
  args << "--check" if check
  args << playbook
  output = IO::Memory.new
  # One real pipe for both streams (2>&1 in the shell): the parse-time
  # [DEPRECATION WARNING] lines and the task output interleave exactly
  # as a terminal sees them, which is what these assertions read.
  status = Process.run("sh", ["-c", "exec \"$0\" \"$@\" 2>&1", BINARY] + args, output: output, input: IO::Memory.new)
  {status, output.to_s, File.expand_path(playbook)}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private PLAY_HEADER = [
  "- hosts: localhost",
  "  connection: local",
  "  gather_facts: false",
  "  tasks:",
]

private UNAVAILABLE_DATACENTER = [
  "    - name: create datacenter",
  "      community.vmware.vmware_datacenter:",
  "        datacenter_name: SC0",
  "        state: present",
]

private DEPRECATED_CLUSTER = [
  "    - name: create cluster",
  "      community.vmware.vmware_cluster:",
  "        datacenter_name: SC0",
  "        cluster_name: AppFactory",
]

private VMWARE_CLUSTER_WARNING = "[DEPRECATION WARNING]: community.vmware.vmware_cluster has been deprecated. " \
                                 "Use vmware.vmware.cluster instead. " \
                                 "This feature will be removed from collection 'community.vmware' version 6.0.0."

private DEPRECATED_POWERSTATE = [
  "    - name: power on vms",
  "      community.vmware.vmware_guest_powerstate:",
  "        name: testvm",
  "        state: powered-on",
]

describe "unported community.vmware module import gate" do
  it "fails the first task with the missing-library error instead of skipping under --check" do
    skip "python on this host can import requests and PyVmomi" if vmware_gate_skips?

    library = missing_vmware_library
    status, output, _path = run_vmware_playbook((PLAY_HEADER + UNAVAILABLE_DATACENTER + DEPRECATED_CLUSTER).join("\n") + "\n", check: true)

    # Real's exit for a failed task (2), not the engine-limit exit 4 the
    # unavailable-module skip produces.
    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Module failed: Failed to import the required Python library (#{library}) on ")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Failed to import the required Python library (#{library}) on ")
    output.must_include("Origin:")
    output.must_include("failed=1")
    output.wont_include("skipped=1")
    output.wont_include("skipped=2")
    output.wont_include("uses unimplemented plugin")
    # A failed task halts the host, so the second task's banner never
    # prints - real never reaches it either.
    output.wont_include("create cluster]")
  end

  it "fails the same way outside check mode" do
    skip "python on this host can import requests and PyVmomi" if vmware_gate_skips?

    status, output, _path = run_vmware_playbook((PLAY_HEADER + UNAVAILABLE_DATACENTER).join("\n") + "\n")

    status.exit_code.must_equal(2)
    output.must_include("Failed to import the required Python library (#{missing_vmware_library}) on ")
    output.must_include("failed=1")
    output.wont_include("skipped=1")
    output.wont_include("skipped=2")
    output.wont_include("uses unimplemented plugin")
  end

  it "still skips a vmware task whose when: is false" do
    status, output, _path = run_vmware_playbook((PLAY_HEADER + [
      "    - name: gated datacenter",
      "      community.vmware.vmware_datacenter:",
      "        datacenter_name: SC0",
      "        state: present",
      "      when: false",
    ]).join("\n") + "\n", check: true)

    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]")
    output.must_include("skipped=1")
    output.wont_include("Failed to import the required Python library")
  end

  it "prints the deprecated module_utils imports' warnings from the executed gate" do
    skip "python on this host can import requests and PyVmomi" if vmware_gate_skips?

    _status, output, _path = run_vmware_playbook((PLAY_HEADER + UNAVAILABLE_DATACENTER).join("\n") + "\n", check: true)

    output.must_include("[DEPRECATION WARNING]: The `ansible.module_utils.common._collections_compat` module is deprecated.")
    output.must_include("[DEPRECATION WARNING]: Importing 'to_text' from 'ansible.module_utils._text' is deprecated.")
    output.must_include("[DEPRECATION WARNING]: Importing 'to_native' from 'ansible.module_utils._text' is deprecated.")
  end

  it "prints real's load-time community.vmware deprecation block for a task the failure never reaches" do
    skip "python on this host can import requests and PyVmomi" if vmware_gate_skips?

    _status, output, path = run_vmware_playbook((PLAY_HEADER + UNAVAILABLE_DATACENTER + DEPRECATED_CLUSTER).join("\n") + "\n", check: true)

    output.must_include(VMWARE_CLUSTER_WARNING)
    # Positioned at the module KEY, like the redirect deprecations, and
    # deduped with the one-time "can be disabled" trailer ahead of it.
    output.must_include("Origin: #{path}:10:7")
    output.must_include("10       community.vmware.vmware_cluster:")
    trailer = "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg."
    output.scan(trailer).size.must_equal(1)
  end

  it "prints every vmware deprecation entry the role's remaining tasks carry" do
    skip "python on this host can import requests and PyVmomi" if vmware_gate_skips?

    _status, output, _path = run_vmware_playbook((PLAY_HEADER + UNAVAILABLE_DATACENTER + [
      "    - name: add esxi host",
      "      community.vmware.vmware_host:",
      "        esxi_hostname: esxi01",
      "        state: present",
      "    - name: create folder",
      "      community.vmware.vcenter_folder:",
      "        folder_name: dvs",
      "        folder_type: vm",
      "    - name: enable drs",
      "      community.vmware.vmware_cluster_drs:",
      "        datacenter_name: SC0",
      "        cluster_name: AppFactory",
      "    - name: enable ha",
      "      community.vmware.vmware_cluster_ha:",
      "        datacenter_name: SC0",
      "        cluster_name: AppFactory",
    ]).join("\n") + "\n", check: true)

    output.must_include("[DEPRECATION WARNING]: community.vmware.vmware_host has been deprecated. " \
                        "Use vmware.vmware.esxi_host and vmware.vmware.esxi_connection instead. " \
                        "This feature will be removed from collection 'community.vmware' version 7.0.0.")
    output.must_include("[DEPRECATION WARNING]: community.vmware.vcenter_folder has been deprecated. " \
                        "Use vmware.vmware.folder instead. " \
                        "This feature will be removed from collection 'community.vmware' version 7.0.0.")
    output.must_include("[DEPRECATION WARNING]: community.vmware.vmware_cluster_drs has been deprecated. " \
                        "Use vmware.vmware.cluster_drs instead. " \
                        "This feature will be removed from collection 'community.vmware' version 6.0.0.")
    output.must_include("[DEPRECATION WARNING]: community.vmware.vmware_cluster_ha has been deprecated. " \
                        "Use vmware.vmware.cluster_ha instead. " \
                        "This feature will be removed from collection 'community.vmware' version 7.0.0.")
  end

  it "prints the vmware_guest_powerstate deprecation for the role's own power-on task" do
    skip "python on this host can import requests and PyVmomi" if vmware_gate_skips?

    _status, output, path = run_vmware_playbook((PLAY_HEADER + DEPRECATED_POWERSTATE).join("\n") + "\n", check: true)

    output.must_include("[DEPRECATION WARNING]: community.vmware.vmware_guest_powerstate has been deprecated. " \
                        "Use vmware.vmware.vm_powerstate instead. " \
                        "This feature will be removed from collection 'community.vmware' version 7.0.0.")
    output.must_include("Origin: #{path}:6:7")
    output.must_include("6       community.vmware.vmware_guest_powerstate:")
  end
end
