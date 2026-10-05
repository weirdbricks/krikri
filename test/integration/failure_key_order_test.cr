require "../minitest_helper"

# FAILED-result registered key orders, pinned to the shapes live-verified
# against ansible-core 2.19.11 by running both engines on a local
# play (hosts: localhost, connection: local), registering each failure
# with ignore_errors: true and dumping `{{ r | to_json }}` (the -v/fatal
# dump sorts alphabetically, so the order is only observable
# programmatically).
#
# A failed command/shell result is NOT the success shape with `failed`
# moved: Ansible runs the module dict (changed/stdout/stderr/rc/cmd/start/
# end/delta), then fail_json's failed/msg, then the derived
# stdout_lines/stderr_lines, then the controller-appended exception -
# see plugins/command.cr's FAILED_KEY_ORDER.
#
# Plain fail_json results (no extra kwargs) register as failed, msg,
# changed, exception - live-verified across slurp (missing file), stat
# (unsupported parameter), file (bad state), fail:, service (missing
# service), getent (unknown database) and mount (unmkdirable path);
# that order is PluginResult's default failed emission now. Modules
# passing extra fail_json kwargs keep them kwargs-FIRST (Ansible's
# fail_json merges failed/msg after the kwargs dict): lineinfile/
# blockinfile/replace's fail_json(rc=257, ...) registers rc, failed,
# msg, changed, exception, and wait_for's timeout registers elapsed,
# failed, msg, changed, exception - all live-verified per module.
#
# Real failures that do NOT route through a module fail_json (the
# controller-side "Task failed:/AnsibleActionFail" shapes - copy's
# failed, msg, exception, changed; uri's file:// failed, changed,
# exception, msg) carry their own pinned key_order or action-level
# shape and are not covered here.

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

describe "plain fail_json registered key order (default failed emission)" do
  it "registers a slurp failure as failed, msg, changed, exception" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: slurp it
            ansible.builtin.slurp:
              src: /nonexistent/krikri-fk-file
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.must_equal(%w[failed msg changed exception])
  end

  it "registers a service failure for a missing service as failed, msg, changed, exception" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: start it
            ansible.builtin.service:
              name: krikri-fk-nosuchsvc
              state: started
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.must_equal(%w[failed msg changed exception])
  end
end

describe "rc-257 missing-file failure key order" do
  it "registers a lineinfile failure on a missing path as rc, failed, msg, changed, exception" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: line it
            ansible.builtin.lineinfile:
              path: /nonexistent-krikri-fk-dir/f
              line: hello
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.must_equal(%w[rc failed msg changed exception])
  end

  it "registers a blockinfile failure on a missing path as rc, failed, msg, changed, exception" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: block it
            ansible.builtin.blockinfile:
              path: /nonexistent-krikri-fk-dir/f
              block: x
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.must_equal(%w[rc failed msg changed exception])
  end

  it "registers a replace failure on a missing path as rc, failed, msg, changed, exception" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: replace it
            ansible.builtin.replace:
              path: /nonexistent-krikri-fk-dir/f
              regexp: a
              replace: b
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.must_equal(%w[rc failed msg changed exception])
  end
end

describe "wait_for timeout registered key order" do
  it "registers a port timeout as elapsed, failed, msg, changed, exception" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: wait for it
            ansible.builtin.wait_for:
              port: 59999
              timeout: 1
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.must_equal(%w[elapsed failed msg changed exception])
  end
end
