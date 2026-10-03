require "../minitest_helper"
require "file_utils"

# Registered-result key orders for the rpm_key/gem/yum_repository/iptables/
# apt_repository/deb822_repository/yum/dnf/dnf5 plugins, pinned to the
# orders live-verified against real ansible-core 2.19.11 (see
# key_order_sweep_test.cr for the general method; the -v dump sorts
# alphabetically, so the order is only observable programmatically).
#
# Verification channels used in this sweep (real ansible-playbook
# 2.19.11, `{{ r | to_json }}` / `{{ r.keys() | list }}` on registered
# tasks):
# - rpm_key, gem, yum/dnf/dnf5, yum_repository, iptables: a throwaway
#   root Fedora 41 podman container running pip-installed
#   ansible-core 2.19.11 (host has no rpm/dnf/gem); iptables additionally
#   through a stateful stub `iptables` binary (no kernel netfilter access
#   in a rootless container) driving the real module's own code paths;
# - apt_repository, deb822_repository: host check mode (unprivileged;
#   the real (mutating) /etc/apt write needs root and carries no
#   separate order - both modules have a single exit_json whose kwarg
#   order is variant-independent, cross-checked against module source);
# - seboolean/sefcontext/seport: SKIPPED - live-verified that all three
#   fail on this host ("Failed to import the required Python library
#   (libsemanage-python / policycoreutils-python)"; no /sys/fs/selinux,
#   no seobject), so no success shape is reachable to verify. No order
#   pinned, no guess.
#
# The pins cover the keys krikri emits, in real's relative order: real's
# registered result additionally carries controller-appended
# ansible_facts (interpreter discovery) / backfilled failed / warnings
# after the module dict, which krikri's module wire omits (the executor's
# own failed-if-absent backfill reproduces the trailing failed: false).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs a playbook whose final task copies `{{ r | to_json }}` into a
# file, then returns the dumped object's key order (writing the dump
# through copy: avoids the display layer's JSON escaping entirely).
private def run_registered_dump(yaml : String) : Array(String)
  dump = PluginSpecHelper.tmp_path("key-order-dump8.json")
  playbook = File.tempname("key-order-sweep8", ".yml")
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

describe "rpm_key plugin result key order (sweep8)" do
  # Real 2.19.11 rpm_key.py has FOUR success exits, all bare
  # exit_json(changed=...) - key imported / already present (state
  # present), key removed / already absent (state absent) - so every
  # success shape registers exactly {changed, failed} (the trailing
  # failed: false is the controller's backfill). Live-verified in a
  # Fedora 41 container for present-changed, present-unchanged and
  # check mode; the absent variants share the same bare-exit shape
  # (module source lines 142/156/160/162). The "Key imported" /
  # "Key already present" msgs were krikri's own borrow - dropped,
  # npm-style.
  KEYID = "cafeb00d"

  GPG_SHIM = <<-SH
    #!/bin/sh
    echo "pub::::deadbeef#{KEYID}:::"
    echo "fpr:::::::::DEADBEEF#{KEYID.upcase}:"
    exit 0
    SH

  RPM_SHIM = <<-'SH'
    #!/bin/sh
    DB="${KRIKRI_FAKE_RPM_DB:?}"
    if [ "$1" = "-q" ] && [ "$2" = "gpg-pubkey" ]; then
      if [ -s "$DB" ]; then cat "$DB"; exit 0; fi
      exit 1
    fi
    if [ "$1" = "--import" ]; then
      echo "cafeb00d" >> "$DB"
      exit 0
    fi
    if [ "$1" = "--erase" ]; then
      : > "$DB"
      exit 0
    fi
    exit 1
    SH

  # Installs fake `gpg` (fixed colon-dump) and `rpm` (gpg-pubkey
  # presence backed by a state file, --import/--erase recorded) at the
  # front of PATH.
  private def with_rpm_key_shims(&)
    bin_dir = File.tempname("krikri-sweep8-rpmkey")
    Dir.mkdir_p(bin_dir)
    gpg = File.join(bin_dir, "gpg")
    File.write(gpg, GPG_SHIM)
    File.chmod(gpg, 0o755)
    rpm = File.join(bin_dir, "rpm")
    File.write(rpm, RPM_SHIM)
    File.chmod(rpm, 0o755)

    db = File.tempname("krikri-sweep8-rpm-db")
    File.delete(db) if File.exists?(db)
    previous_path = ENV["PATH"]?
    previous_db = ENV["KRIKRI_FAKE_RPM_DB"]?
    ENV["PATH"] = "#{bin_dir}:#{ENV["PATH"]?}"
    ENV["KRIKRI_FAKE_RPM_DB"] = db
    begin
      yield db
    ensure
      previous_path ? (ENV["PATH"] = previous_path) : ENV.delete("PATH")
      previous_db ? (ENV["KRIKRI_FAKE_RPM_DB"] = previous_db) : ENV.delete("KRIKRI_FAKE_RPM_DB")
      FileUtils.rm_r(bin_dir)
      File.delete(db) if File.exists?(db)
    end
  end

  it "registers a fresh import as changed, failed (no msg)" do
    with_rpm_key_shims do
      key_path = File.tempname("krikri-sweep8-key")
      File.write(key_path, "fake key material\n")
      keys = run_registered_dump(<<-YAML)
        - name: repro
          hosts: localhost
          gather_facts: false
          connection: local
          tasks:
            - name: import key
              ansible.builtin.rpm_key:
                key: #{key_path}
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

  it "registers an already-present rerun in the same shape" do
    with_rpm_key_shims do |db|
      key_path = File.tempname("krikri-sweep8-key2")
      File.write(key_path, "fake key material\n")
      play = <<-YAML
        - name: repro
          hosts: localhost
          gather_facts: false
          connection: local
          tasks:
            - name: import key
              ansible.builtin.rpm_key:
                key: #{key_path}
              register: r
            - name: dump
              ansible.builtin.copy:
                content: |-
                  {{ r | to_json }}
                dest: KRIKRI_DUMP_PATH
      YAML
      run_registered_dump(play)
      File.exists?(db).must_equal(true)
      keys = run_registered_dump(play)
      keys.must_equal(["changed", "failed"])
    end
  end

  it "registers an absent no-op as the same bare shape" do
    with_rpm_key_shims do
      keys = run_registered_dump(<<-YAML)
        - name: repro
          hosts: localhost
          gather_facts: false
          connection: local
          tasks:
            - name: absent no-op
              ansible.builtin.rpm_key:
                key: #{KEYID}
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

  it "registers a key removal as changed in the same bare shape" do
    with_rpm_key_shims do |db|
      File.write(db, "#{KEYID}\n")
      keys = run_registered_dump(<<-YAML)
        - name: repro
          hosts: localhost
          gather_facts: false
          connection: local
          tasks:
            - name: remove key
              ansible.builtin.rpm_key:
                key: 0xdeadbeef#{KEYID}
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
end
