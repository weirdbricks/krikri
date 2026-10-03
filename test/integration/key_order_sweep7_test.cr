require "../minitest_helper"
require "file_utils"

# Registered-result key orders for the script/make/expect/htpasswd/npm/
# package/apt_repository/deb822_repository plugins, pinned to the orders
# live-verified against real ansible-core 2.19.11 by registering each
# module's result and dumping `{{ r | to_json }}` (see
# key_order_sweep_test.cr for the general method; the -v dump sorts
# alphabetically, so the order is only observable programmatically).
#
# The pins cover the keys krikri emits, in real's relative order: real's
# registered result additionally carries controller-appended
# ansible_facts (interpreter discovery) and backfilled failed: false /
# warnings after the module dict, which krikri's module wire omits.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a playbook whose final task copies `{{ r | to_json }}` into a
# file, then returns the dumped object's key order (writing the dump
# through copy: avoids the display layer's JSON escaping entirely).
private def run_registered_dump(yaml : String) : Array(String)
  dump = PluginSpecHelper.tmp_path("key-order-dump7.json")
  playbook = File.tempname("key-order-sweep7", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  JSON.parse(File.read(dump)).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def unique_tmp(*parts : String) : String
  PluginSpecHelper.tmp_path("#{parts.join("-")}-#{Random::Secure.hex(4)}")
end

describe "script plugin result key order (sweep7)" do
  # Real 2.19.11's script ACTION plugin builds its own result dict
  # (rc, stdout, stdout_lines, stderr, stderr_lines, changed) around the
  # module run; failed: false lands after changed via the executor
  # backfill. Live-verified with a plain run and a passing-args run.
  it "registers a successful run as rc, stdout, stdout_lines, stderr, stderr_lines, changed, failed" do
    script = unique_tmp("script-order")
    File.write(script, "#!/bin/sh\necho probe-out\n")
    File.chmod(script, 0o755)

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: run it
            ansible.builtin.script: #{script}
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["rc", "stdout", "stdout_lines", "stderr", "stderr_lines", "changed", "failed"])
  end

  it "registers a holding creates gate as skipped, msg, changed" do
    marker = unique_tmp("script-order-marker")
    File.touch(marker)
    script = unique_tmp("script-order-skip")
    File.write(script, "#!/bin/sh\necho nope\n")
    File.chmod(script, 0o755)

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: gated run
            ansible.builtin.script: #{script}
            register: r
            args:
              creates: #{marker}
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    # Real's action-side skip registers exactly [skipped, msg, changed]
    # (no failed key); krikri's gate runs module-side, so the executor's
    # module-result failed: false backfill still appends after changed -
    # a residual CONTENT divergence, the ORDER of the shared keys is the
    # pin under test here.
    keys.first(3).must_equal(["skipped", "msg", "changed"])
  end
end
