require "../minitest_helper"
require "file_utils"

# Registered-result key orders for the storage plugins (lvg, lvol,
# parted, zfs, mount), pinned to the orders live-captured against real
# ansible-core on a real Ubuntu 22.04 host in round 992003
# (kop_storage): every probed task registered r and a following debug
# emitted `{{ r | to_json }}`, and krikri-role-tester's keyorder report
# compared the two engines' registered top-level key orders.
#
# Root-free verification boundary on this dev box (no passwordless
# sudo; no loop devices, no zfs): only the shapes below are pinned
# end-to-end here. The remaining probe shapes - lvg_create/lvg_exists
# (vgcreate needs root), lvol_create/lvol_exists/lvol_check/lvol_fail
# (a real VG), zfs_create/zfs_exists/zfs_check/zfs_fail (a real pool),
# and mount's mounted-state shapes - are verified against the captured
# real outputs only; they need privileges this suite must not assume.
# Their wire shapes are built from the same code paths these pins
# exercise (the same PluginResult constructions with the same
# key_order lists).
#
# The single shared-fix pin: Ansible's controller appends the collected
# `deprecations` AFTER the failed/changed backfill, so mount registers
# ..., fstype, failed, deprecations (previously krikri's wire-side
# deprecations landed before the backfilled failed key).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Same harness as key_order_sweep_test.cr (distinct name so the files
# can coexist in the generated minitest entrypoint): runs a playbook,
# then returns the dumped registered result's key order.
private def run_registered_dump12(yaml : String) : JSON::Any
  dump = PluginSpecHelper.tmp_path("key-order-dump12.json")
  playbook = File.tempname("key-order-sweep12", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  JSON.parse(File.read(dump))
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def lvm_tool_available?(name : String) : Bool
  !Process.find_executable(name).nil?
end

describe "storage plugin registered key order (round 992003 kop_storage)" do
  it "parted create registers [changed, disk, partitions, script, failed] on an unlabeled device" do
    # The loop-device state the round's probe starts from: a blank
    # device whose `parted -s -m ... print` exits non-zero with
    # "unrecognised disk label". Ansible parses the BYT; header anyway
    # (table "unknown"), builds the mklabel+mkpart script and succeeds -
    # krikri previously failed the task outright (the round's parted
    # recap divergence, py changed=17 vs cr changed=16).
    tmp = PluginSpecHelper.tmp_path("parted-create")
    FileUtils.mkdir_p(tmp)

    dump = run_registered_dump12(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - command: "truncate -s 200M #{tmp}/disk.img"
            args:
              creates: #{tmp}/disk.img
            changed_when: false
          - community.general.parted:
              device: #{tmp}/disk.img
              number: 1
              state: present
              label: msdos
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    dump.as_h.keys.must_equal(["changed", "disk", "partitions", "script", "failed"])
    dump["changed"].as_bool.must_equal(true)
    dump["script"].as_a.map(&.as_s).must_equal(["unit", "KiB", "mklabel", "msdos", "mkpart", "primary", "0%", "100%"])
    dump["disk"].as_h.keys.must_equal(["dev", "size", "unit", "table", "model", "logical_block", "physical_block"])
    dump["disk"]["table"].as_s.must_equal("msdos")
    dump["partitions"].as_a.size.must_equal(1)
    dump["partitions"][0].as_h.keys.must_equal(["num", "begin", "end", "size", "fstype", "name", "flags", "unit"])
    dump["partitions"][0]["num"].as_i64.must_equal(1)
    dump["partitions"][0]["begin"].as_f.must_equal(0.5)
    dump["failed"].as_bool.must_equal(false)
  end

  it "parted idempotent rerun registers the same key order with an empty script" do
    tmp = PluginSpecHelper.tmp_path("parted-exists")
    FileUtils.mkdir_p(tmp)

    keys = run_registered_dump12(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - command: "truncate -s 200M #{tmp}/disk.img"
            args:
              creates: #{tmp}/disk.img
            changed_when: false
          - community.general.parted:
              device: #{tmp}/disk.img
              number: 1
              state: present
              label: msdos
            changed_when: false
          - community.general.parted:
              device: #{tmp}/disk.img
              number: 1
              state: present
              label: msdos
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML

    keys.as_h.keys.must_equal(["changed", "disk", "partitions", "script", "failed"])
    keys["changed"].as_bool.must_equal(false)
    keys["script"].as_a.must_be_empty
    keys["partitions"][0]["num"].as_i64.must_equal(1)
  end

  it "parted failure on a missing device registers [rc, out, err, failed, msg, changed, exception]" do
    tmp = PluginSpecHelper.tmp_path("parted-fail")
    FileUtils.mkdir_p(tmp)

    keys = run_registered_dump12(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.general.parted:
              device: #{tmp}/nosuch.img
              number: 1
              state: present
            register: r
            ignore_errors: true
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML

    keys.as_h.keys.must_equal(["rc", "out", "err", "failed", "msg", "changed", "exception"])
    keys["failed"].as_bool.must_equal(true)
    keys["msg"].as_s.starts_with?("Error while getting device information with parted script:").must_equal(true)
    keys["exception"].as_s.must_equal("(traceback unavailable)")
  end

  it "rejects a number below 1 with Ansible's exact message" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/null", "number" => "0", "state" => "present"})

    result.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
    result["msg"].as_s.must_equal("The partition number must be greater then 0.")
  end

  it "lvg failure on a missing PV device registers [failed, msg, changed, exception] with Ansible's Device not found. message" do
    # real lvg.py checks every requested PV for existence (after
    # realpath) before any LVM command runs - the round's lvg_fail
    # capture. Previously krikri marched into vgcreate and invented its
    # own "Failed to create volume group ..." wording.
    skip("no vgs binary") unless lvm_tool_available?("vgs")

    tmp = PluginSpecHelper.tmp_path("lvg-fail")
    FileUtils.mkdir_p(tmp)
    missing_pv = File.join(tmp, "nosuch_pv.img")

    keys = run_registered_dump12(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.general.lvg:
              vg: kop_vg_keyorder
              pvs: #{missing_pv}
              state: present
            register: r
            ignore_errors: true
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML

    keys.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
    keys["failed"].as_bool.must_equal(true)
    keys["msg"].as_s.must_equal("Device #{missing_pv} not found.")
  end

  it "lvol failure on a missing VG registers [rc, err, failed, msg, changed, exception] (fail_json rc/err kwargs lead)" do
    skip("no lvm binary") unless lvm_tool_available?("lvm")

    keys = run_registered_dump12(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.general.lvol:
              vg: kop_vg_definitely_not_here
              lv: kop_lv
              size: 64M
              state: present
            register: r
            ignore_errors: true
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML

    keys.as_h.keys.must_equal(["rc", "err", "failed", "msg", "changed", "exception"])
    keys["failed"].as_bool.must_equal(true)
    keys["msg"].as_s.must_equal("Volume group kop_vg_definitely_not_here does not exist.")
    (keys["rc"].as_i64 > 0).must_equal(true)
    keys["changed"].as_bool.must_equal(false)
  end

  it "mount success registers [..., fstype, failed, deprecations] - deprecations AFTER the backfilled failed" do
    fstab = PluginSpecHelper.tmp_path("mount-keyorder.fstab")

    keys = run_registered_dump12(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.posix.mount:
              path: /var/tmp/kop-mnt-keyorder
              src: tmpfs
              fstype: tmpfs
              opts: size=16m
              state: present
              fstab: #{fstab}
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML

    keys.as_h.keys.must_equal([
      "changed", "name", "opts", "dump", "passno", "fstab", "boot",
      "backup_file", "src", "fstype", "failed", "deprecations",
    ])
    keys["changed"].as_bool.must_equal(true)
    keys["deprecations"].as_a[0]["msg"].as_s.must_equal(
      "Passing `warnings` to `exit_json` or `fail_json` is deprecated.")
  end

  it "mount unmounted registers [..., backup_file, failed, deprecations] (no src/fstype, deprecations last)" do
    fstab = PluginSpecHelper.tmp_path("mount-unmounted-keyorder.fstab")
    File.write(fstab, "tmpfs /var/tmp/kop-mnt-keyorder2 tmpfs defaults 0 0\n")

    keys = run_registered_dump12(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.posix.mount:
              path: /var/tmp/kop-mnt-keyorder2
              state: unmounted
              fstab: #{fstab}
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML

    keys.as_h.keys.must_equal([
      "changed", "name", "opts", "dump", "passno", "fstab", "boot",
      "backup_file", "failed", "deprecations",
    ])
    # An unmounted against a path that is not mounted (all this sandbox
    # can do) is the round's mount_unmounted_again capture: changed
    # false, same key order - the changed-true umount variant differs
    # only in the changed value.
    keys["changed"].as_bool.must_equal(false)
    keys["backup_file"].as_s.must_equal("")
  end

  it "zfs on a non-ZFS host registers the missing-binary failure [failed, msg, changed, exception]" do
    # zfs_create/zfs_exists/zfs_check/zfs_fail shapes need a real pool
    # (capture-verified only - see the file comment); the only shape
    # this environment can produce is the binary lookup failure, whose
    # registered order follows the plain fail_json default.
    skip("zfs binaries present - nothing to pin rootless") if lvm_tool_available?("zfs") && lvm_tool_available?("zpool")

    keys = run_registered_dump12(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.general.zfs:
              name: koppool/kopfs
              state: present
            register: r
            ignore_errors: true
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML

    keys.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
    keys["msg"].as_s.starts_with?("Failed to find required executable").must_equal(true)
  end
end
