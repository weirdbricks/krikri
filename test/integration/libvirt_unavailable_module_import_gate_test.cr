require "../minitest_helper"
require "../../src/krikri/plugin_helpers/python_lib_gate"

# community.libvirt's `virt` is not ported, but real ansible still runs
# it: virt.py imports `libvirt` then `lxml` at MODULE level and fails the
# task with its own "<library> module is not importable" text before it
# touches a domain, and it declares supports_check_mode=True, so a target
# without those libraries - under --check too - gets a FAILED task, never
# a skip (siavashoutadi.virt_guest, issue #1742: real failed its define
# task, krikri skipped it and the next virt task and exited 4 against
# real's 2). This engine therefore runs the synthesized gate in
# PythonModuleRunner.libvirt_import_gate_source, which reproduces the
# failure, the library order and the [DEPRECATION WARNING] line virt.py's
# deprecated `to_native` import makes real print. When both libraries
# import, the module would go on to talk to a libvirt daemon this engine
# does not implement, so the designed unavailable-module skip applies.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# The gate's own order: it only falls through to the sentinel when BOTH
# libraries import, so a host carrying one of them still fails the task.
private def libvirt_gate_imports_cleanly? : Bool
  Krikri.missing_python_library("libvirt", "libvirt").nil? &&
    Krikri.missing_python_library("lxml", "lxml").nil?
end

private def run_virt_playbook(yaml : String, check : Bool = false) : {Process::Status, String}
  playbook = File.tempname("libvirt-import-gate", ".yml")
  File.write(playbook, yaml)
  args = ["-i", INVENTORY]
  args << "--check" if check
  args << playbook
  output = IO::Memory.new
  # One pipe for both streams, so the task's stdout lines, the
  # [DEPRECATION WARNING] on stderr and the fatal line read in the order
  # a terminal shows them.
  status = Process.run("sh", ["-c", "exec \"$0\" \"$@\" 2>&1", BINARY] + args, output: output, input: IO::Memory.new)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private CREATE_GUEST_PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: Create the guest
        virt:
          name: vm1
          command: define
          xml: "<domain type='kvm'><name>vm1</name></domain>"
      - name: Ensure the guest is running and started at boot
        virt:
          name: vm1
          autostart: true
          state: running
  YAML

describe "unported community.libvirt.virt import gate" do
  it "fails the define task instead of skipping under --check" do
    skip "python on this host can import libvirt and lxml" if libvirt_gate_imports_cleanly?

    status, output = run_virt_playbook(CREATE_GUEST_PLAYBOOK, check: true)

    # Real's own exit for a failed task (2), not the engine-limit exit 4
    # the unavailable-module skip produces.
    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Module failed: The `libvirt` module is not importable. Check the requirements.")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"The `libvirt` module is not importable. Check the requirements.\"}")
    output.must_include("Origin:")
    # virt.py's own module-level import block ends with the deprecated
    # `to_native` import, which is the warning real prints for this task.
    output.must_include("[DEPRECATION WARNING]: Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
                        "This feature will be removed from ansible-core version 2.24. " \
                        "Use ansible.module_utils.common.text.converters instead.")
    output.must_include("failed=1")
    output.wont_include("skipped=1")
    output.wont_include("skipped=2")
    # A failed task halts the host, so the second virt task never shows a
    # banner (real never reaches it either).
    output.wont_include("Ensure the guest is running and started at boot")
    # The engine-limit warning and its exit-4 accounting stay out: the
    # task failed like a module failure, it was not "unavailable".
    output.wont_include("uses unimplemented plugin")
  end

  it "gates the community.libvirt.virt FQCN spelling too" do
    skip "python on this host can import libvirt and lxml" if libvirt_gate_imports_cleanly?

    status, output = run_virt_playbook(<<-YAML, check: true)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: fqcn define
            community.libvirt.virt:
              name: vm1
              command: define
              xml: "<domain type='kvm'><name>vm1</name></domain>"
      YAML

    status.exit_code.must_equal(2)
    output.must_include("The `libvirt` module is not importable. Check the requirements.")
    output.must_include("failed=1")
    output.wont_include("uses unimplemented plugin")
  end

  it "still skips a virt task whose when: is false" do
    status, output = run_virt_playbook(<<-YAML, check: true)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gated define
            virt:
              name: vm1
              command: define
              xml: "<domain type='kvm'><name>vm1</name></domain>"
            when: false
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]")
    output.must_include("skipped=1")
    output.must_include("SHOULD-RUN-AFTER")
    output.wont_include("The `libvirt` module is not importable")
  end

  it "falls back to the unavailable-module skip when both libraries import" do
    # Stub packages on PYTHONPATH make the gate's two imports succeed; the
    # module would then go on to talk to a libvirt daemon this engine does
    # not implement, so the designed unavailable-module skip (and its
    # exit-4 accounting) applies, as before the gate.
    fake_lib = PluginSpecHelper.tmp_path("libvirt-gate-fake-lib")
    FileUtils.mkdir_p(fake_lib)
    File.write(File.join(fake_lib, "libvirt.py"), "class libvirtError(Exception):\n    pass\n")
    File.write(File.join(fake_lib, "lxml.py"), "etree = None\n")

    playbook = File.tempname("libvirt-import-gate", ".yml")
    File.write(playbook, CREATE_GUEST_PLAYBOOK)
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "--check", playbook], output: output,
      error: output, env: ENV.to_h.merge({"PYTHONPATH" => fake_lib}))

    status.exit_code.must_equal(4)
    output.to_s.must_include("uses unimplemented plugin: virt")
    output.to_s.must_include("skipped=2")
    output.to_s.wont_include("is not importable")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
