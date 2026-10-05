require "../minitest_helper"
require "file_utils"
require "json"

# Registered-result key orders for the sysctl/mount_facts/modprobe
# plugins, pinned to the orders captured from REAL ansible-core 2.19.11
# on a real Ubuntu 22.04 host (krikri-role-tester round 992001, probe
# playbook testing/keyorder_probes/kop_kernel, `{{ r | to_json }}`
# dumps under ~/scratch/krt-results/992001_atlantic_local_kop_kernel).
#
# The sysctl/modprobe failures cannot run for real rootless in the test
# containers beyond what these specs do (a real `sysctl -w` needs
# root; modprobe of a nonexistent module fails identically unprivileged),
# so the failure-shape pins reproduce the capture with the same
# underlying commands the real host ran.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a playbook whose final task copies `{{ r | to_json }}` into a
# file, then returns the dumped object's key order (writing the dump
# through copy: avoids the display layer's JSON escaping entirely).
private def run_registered_dump(yaml : String) : Array(String)
  dump = PluginSpecHelper.tmp_path("key-order-dump-kop.json")
  playbook = File.tempname("key-order-kop", ".yml")
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

describe "sysctl plugin result key order (round 992001)" do
  # Ansible.posix.sysctl has exactly one success exit -
  # module.exit_json(changed=result.changed) (sysctl.py:416) - so the
  # registered result is the bare changed plus the controller-backfilled
  # failed: false, and nothing else (no name/sysctl_file echo, no msg).
  # Capture-verified all three probe shapes: set (changed), idempotent
  # rerun, and check mode all register [changed, failed].
  it "registers a fresh set as changed, failed - nothing else" do
    conf = unique_tmp("kop-sysctl.conf")

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: set it
            ansible.posix.sysctl:
              name: vm.swappiness
              value: "10"
              state: present
              sysctl_file: #{conf}
              reload: false
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["changed", "failed"])
  end

  it "registers an idempotent rerun as changed, failed" do
    conf = unique_tmp("kop-sysctl-idem.conf")
    File.write(conf, "vm.swappiness=10\n")

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: set it again
            ansible.posix.sysctl:
              name: vm.swappiness
              value: "10"
              state: present
              sysctl_file: #{conf}
              reload: false
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["changed", "failed"])
  end

  it "registers a check-mode set as changed, failed" do
    conf = unique_tmp("kop-sysctl-check.conf")
    File.write(conf, "vm.swappiness=10\n")

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: set it in check mode
            ansible.posix.sysctl:
              name: vm.swappiness
              value: "12"
              state: present
              sysctl_file: #{conf}
              reload: false
            check_mode: true
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

describe "mount_facts plugin result key order (round 992001)" do
  # Real mount_facts.py's single exit is
  # module.exit_json(ansible_facts={...}) (mount_facts.py:647): no msg,
  # no changed on the wire. The controller backfills failed, then
  # changed, then appends warnings - capture-verified:
  # [ansible_facts, failed, changed] plain and
  # [ansible_facts, failed, changed, warnings] with the repeat-mounts
  # warning present.
  it "registers plain gather as ansible_facts, failed, changed" do
    # A single-entry custom source (not the host's /proc/mounts, whose
    # repeat mounts would trip the dedup warning) keeps the no-warnings
    # shape deterministic.
    source = unique_tmp("kop-clean-mounts")
    File.write(source, "/dev/a /kopclean ext4 defaults 0 0\n")

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: gather
            ansible.builtin.mount_facts:
              sources: '["#{source}"]'
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["ansible_facts", "failed", "changed"])
  end

  it "registers a gather with the repeat-mounts warning as ansible_facts, failed, changed, warnings" do
    source = unique_tmp("kop-dup-mounts")
    File.write(source, "/dev/a /dup ext4 defaults 0 0\n/dev/b /dup ext4 defaults 0 0\n/dev/c /other ext4 defaults 0 0\n")

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: gather
            ansible.builtin.mount_facts:
              sources: '["#{source}"]'
            register: r
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["ansible_facts", "failed", "changed", "warnings"])
  end

  # Nested shape, same capture: each mount entry serializes as the fstab
  # columns, then the statvfs stats with size_total/size_available
  # leading the block_* group, then ansible_context, then uuid LAST.
  # (Wire-level pin - the registered dump helper only exposes top-level
  # keys.)
  it "serializes each mount entry in Ansible's field order" do
    source = unique_tmp("kop-entry-order-mounts")
    mountpoint = unique_tmp("kop-entry-order-dir")
    Dir.mkdir_p(mountpoint)
    File.write(source, "/dev/a #{mountpoint} ext4 defaults 0 0\n")

    result = PluginSpecHelper.run("mount_facts", {"sources" => "[\"#{source}\"]"})
    entry = result["ansible_facts"]["mount_points"].as_h[mountpoint].as_h

    entry.keys.must_equal([
      "device", "mount", "fstype", "options", "dump", "passno",
      "size_total", "size_available",
      "block_size", "block_total", "block_available", "block_used",
      "inode_total", "inode_available", "inode_used",
      "ansible_context", "uuid",
    ])
  end
end

private MODPROBE_BUILTIN = "/lib/modules/#{File.read("/proc/sys/kernel/osrelease").chomp}/modules.builtin"

private def modprobe_available? : Bool
  !Process.find_executable("modprobe").nil? ||
    %w[/sbin /usr/sbin /bin /usr/bin].any? { |dir| File::Info.executable?(File.join(dir, "modprobe")) }
end

describe "modprobe plugin failure key order (round 992001)" do
  # Real modprobe.py's load_module/unload_module failures are
  # fail_json(msg=err, rc=rc, stdout=out, stderr=err, **self.result)
  # (modprobe.py:125/283): msg is fail_json's named parameter, so the
  # kwargs dict is rc/stdout/stderr plus the result property's
  # changed/name/params/state, basic.py appends failed then msg, the
  # action layer derives stdout_lines/stderr_lines, and the exception
  # lands last - capture-verified order below. modprobe of a
  # nonexistent module fails identically unprivileged (same FATAL
  # message shape the capture host produced).
  it "registers a failed load with Ansible's full kwargs-lead shape" do
    skip "no modprobe binary on this host" unless modprobe_available?
    skip "no #{MODPROBE_BUILTIN} on this host" unless File.exists?(MODPROBE_BUILTIN)

    keys = run_registered_dump(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: load a nonexistent module
            community.general.modprobe:
              name: krikri-kop-no-such-module
              state: present
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
    YAML

    keys.must_equal(["rc", "stdout", "stderr", "changed", "name", "params", "state", "failed", "msg", "stdout_lines", "stderr_lines", "exception"])
  end

  # Value-level pins for the same failure (capture: rc 1, empty stdout,
  # msg identical to stderr including the trailing newline, stderr_lines
  # the splitlines of stderr, changed false, params "").
  it "carries Ansible's failure values: rc 1, msg == stderr, derived lines" do
    skip "no modprobe binary on this host" unless modprobe_available?
    skip "no #{MODPROBE_BUILTIN} on this host" unless File.exists?(MODPROBE_BUILTIN)

    result = PluginSpecHelper.run("modprobe", {"name" => "krikri-kop-no-such-module", "state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["rc"].as_i.must_equal(1)
    result["stdout"].as_s.must_equal("")
    stderr = result["stderr"].as_s
    stderr.includes?("krikri-kop-no-such-module").must_equal(true)
    result["msg"].as_s.must_equal(stderr)
    result["name"].as_s.must_equal("krikri-kop-no-such-module")
    result["params"].as_s.must_equal("")
    result["state"].as_s.must_equal("present")
    result["stdout_lines"].as_a.map(&.as_s).must_equal([] of String)
    result["stderr_lines"].as_a.map(&.as_s).must_equal(stderr.chomp.split("\n"))
  end
end
