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

describe "make plugin result key order (sweep7)" do
  # Real community.general make 2.19.11 exit_json's
  # (changed, failed=False, stdout, stderr, target, targets, params,
  # chdir, file, jobs, command) - failed EXPLICITLY second, raw params
  # echoed back (null when absent). Live-verified changed and unchanged
  # against a Makefile whose target depends on a created file.
  it "registers a fresh build as changed, failed, stdout, stderr, target, targets, params, chdir, file, jobs, command" do
    dir = unique_tmp("make-order")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "Makefile"), "all: marker.txt\n\nmarker.txt:\n\ttouch marker.txt\n")

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: build it
            community.general.make:
              chdir: #{dir}
              target: all
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["changed", "failed", "stdout", "stderr", "target", "targets", "params", "chdir", "file", "jobs", "command", "stdout_lines", "stderr_lines"])
  end

  it "registers an up-to-date rerun in the same order" do
    dir = unique_tmp("make-order-unchanged")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "Makefile"), "all: marker.txt\n\nmarker.txt:\n\ttouch marker.txt\n")

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: build it
            community.general.make:
              chdir: #{dir}
              target: all
            register: r1
          - name: rebuild
            community.general.make:
              chdir: #{dir}
              target: all
            register: r2
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r2 | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["changed", "failed", "stdout", "stderr", "target", "targets", "params", "chdir", "file", "jobs", "command", "stdout_lines", "stderr_lines"])
  end
end

describe "package plugin result key order (sweep7)" do
  # Real 2.19.11's package: action plugin delegates to apt on this host,
  # so the registered shape IS apt's. Live-verified (unprivileged:
  # unchanged paths + check mode, whose --simulate runs need no root):
  # unchanged present = changed, cache_updated, cache_update_time; bare
  # absent no-op = changed; check-mode install/remove = changed, stdout,
  # stderr, diff, cache_updated, cache_update_time, stdout_lines,
  # stderr_lines. The real (mutating) install/remove paths need root and
  # carry NO pin.
  it "registers an unchanged present as changed, cache_updated, cache_update_time" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: present installed
            ansible.builtin.package:
              name: bash
              state: present
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["changed", "cache_updated", "cache_update_time", "failed"])
  end

  it "registers an absent no-op as just changed" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: absent missing
            ansible.builtin.package:
              name: krikri-sweep7-nonexistent-pkg
              state: absent
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["changed", "failed"])
  end

  it "registers a check-mode install as the --simulate shape" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: check install
            ansible.builtin.package:
              name: cowsay
              state: present
            check_mode: true
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["changed", "stdout", "stderr", "diff", "cache_updated", "cache_update_time", "stdout_lines", "stderr_lines", "failed"])
  end

  it "registers a check-mode remove as the --simulate shape too" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: check remove
            ansible.builtin.package:
              name: 7zip
              state: absent
            check_mode: true
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["changed", "stdout", "stderr", "diff", "cache_updated", "cache_update_time", "stdout_lines", "stderr_lines", "failed"])
  end
end

describe "npm plugin result key order (sweep7)" do
  # Real 2.19.11 community.general npm has a SINGLE exit -
  # exit_json(changed=changed) - so every success shape registers just
  # changed (no msg/stdout; the "Package ..."-style msgs were krikri's
  # own borrow, now dropped). Live-verified with the offline-safe
  # state=absent-on-not-installed case.
  it "registers an absent no-op as just changed" do
    dir = unique_tmp("npm-order")
    FileUtils.mkdir_p(dir)
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: absent no-op
            community.general.npm:
              path: #{dir}
              name: krikri-sweep7-nonexistent-pkg
              state: absent
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["changed", "failed"])
  end
end

describe "htpasswd plugin result key order (sweep7)" do
  # Real 2.19.11 community.general htpasswd exit_json's (msg=...,
  # changed=...) with NO path key in the result - live-verified create
  # (msg, changed), idempotent rerun (msg, changed), update and remove.
  it "registers a fresh create as msg, changed" do
    path = unique_tmp("htpasswd-order")
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: create it
            community.general.htpasswd:
              path: #{path}
              name: user1
              password: secret1
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["msg", "changed", "failed"])
  end

  it "registers an idempotent rerun in the same order" do
    path = unique_tmp("htpasswd-order-unchanged")
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: create it
            community.general.htpasswd:
              path: #{path}
              name: user1
              password: secret1
            register: r1
          - name: rerun
            community.general.htpasswd:
              path: #{path}
              name: user1
              password: secret1
            register: r2
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r2 | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["msg", "changed", "failed"])
  end
end

describe "expect plugin result key order (sweep7)" do
  # Real 2.19.11 expect.py builds result = dict(cmd, stdout, rc, start,
  # end, delta, changed) and the creates:/removes: skip exits
  # exit_json(cmd, stdout, changed, rc) - live-verified both, with
  # stdout_lines after changed/rc in each.
  it "registers a successful run as cmd, stdout, rc, start, end, delta, changed, stdout_lines" do
    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: run it
            ansible.builtin.expect:
              command: echo hello
              responses:
                .$: ""
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["cmd", "stdout", "rc", "start", "end", "delta", "changed", "stdout_lines", "failed"])
  end

  it "registers a holding creates gate as cmd, stdout, changed, rc, stdout_lines" do
    marker = unique_tmp("expect-order-marker")
    File.touch(marker)

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: gated run
            ansible.builtin.expect:
              command: echo hello
              responses:
                .$: ""
              creates: #{marker}
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["cmd", "stdout", "changed", "rc", "stdout_lines", "failed"])
  end
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
