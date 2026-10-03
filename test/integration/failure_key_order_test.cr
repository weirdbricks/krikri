require "../minitest_helper"

# FAILED-result registered key orders, pinned to the shapes live-verified
# against real ansible-core 2.19.11 by running both engines on a local
# play (hosts: localhost, connection: local), registering each failure
# with ignore_errors: true and dumping `{{ r | to_json }}` (the -v/fatal
# dump sorts alphabetically, so the order is only observable
# programmatically).
#
# A failed command/shell result is NOT the success shape with `failed`
# moved: real runs the module dict (changed/stdout/stderr/rc/cmd/start/
# end/delta), then fail_json's failed/msg, then the derived
# stdout_lines/stderr_lines, then the controller-appended exception -
# see plugins/command.cr's FAILED_KEY_ORDER. The generic failed order
# for plain fail_json results lives in the later describes (PluginResult's
# default failure emission).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a playbook whose final task copies `{{ r | to_json }}` into a
# file, then returns the dumped object's key order (writing the dump
# through copy: avoids the display layer's JSON escaping entirely).
private def run_registered_dump(yaml : String) : Array(String)
  dump = PluginSpecHelper.tmp_path("failure-key-order-dump.json")
  playbook = File.tempname("failure-key-order", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  JSON.parse(File.read(dump)).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "command/shell failed-result key order" do
  it "registers a failed command (rc != 0) as changed, stdout, stderr, rc, cmd, start, end, delta, failed, msg, stdout_lines, stderr_lines, exception" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: fail it
            ansible.builtin.command: /bin/false
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.must_equal(%w[changed stdout stderr rc cmd start end delta failed msg stdout_lines stderr_lines exception])
  end

  it "registers a failed shell (rc != 0) in the same order with cmd as a string" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: fail it
            ansible.builtin.shell: /bin/false
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.must_equal(%w[changed stdout stderr rc cmd start end delta failed msg stdout_lines stderr_lines exception])
  end
end
