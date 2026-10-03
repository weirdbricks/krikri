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
  status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
  JSON.parse(File.read(dump)).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def unique_tmp(*parts : String) : String
  PluginSpecHelper.tmp_path("#{parts.join("-")}-#{Random::Secure.hex(4)}")
end

describe "rpm_key plugin result key order (sweep8)" do
  # Puts a stub rpm first on the process-wide PATH: serialize with the
  # other ENV-touching tests (see test/minitest_helper.cr).
  serial!

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
      run_registered_dump(play.gsub("            # STATE_SLOT\n", ""))
      File.exists?(db).must_equal(true)
      keys = run_registered_dump(play.gsub("            # STATE_SLOT\n", ""))
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

describe "gem plugin result key order (sweep8)" do
  # Real community.general gem.py builds every success result as
  # name, state, version (only when requested), changed and exits with
  # exit_json(**result) - no msg/stdout. Live-verified in a Fedora 41
  # container (changed install, unchanged rerun, check mode all register
  # exactly {name, state, changed, failed}). krikri's success paths now
  # echo name/state (+ version when requested) and dropped the borrowed
  # "Gem installed"/"already ..." msgs and the raw gem stdout.
  serial!

  GEM_SHIM = <<-'SH'
    #!/bin/sh
    DB="${KRIKRI_FAKE_GEM_DB:?}"
    case "$1" in
      --version) echo "RubyGems 3.5.0"; exit 0;;
      list) grep -q "^ko-gem " "$DB" 2>/dev/null && echo "ko-gem (1.0)"; exit 0;;
      install) echo "ko-gem (1.0)" >> "$DB"; exit 0;;
      uninstall) sed -i '/^ko-gem /d' "$DB" 2>/dev/null; exit 0;;
    esac
    exit 0
    SH

  private def with_gem_shim(&)
    bin_dir = File.tempname("krikri-sweep8-gem")
    Dir.mkdir_p(bin_dir)
    gem = File.join(bin_dir, "gem")
    File.write(gem, GEM_SHIM)
    File.chmod(gem, 0o755)
    db = File.tempname("krikri-sweep8-gem-db")
    File.delete(db) if File.exists?(db)
    previous_path = ENV["PATH"]?
    previous_db = ENV["KRIKRI_FAKE_GEM_DB"]?
    ENV["PATH"] = "#{bin_dir}:#{ENV["PATH"]?}"
    ENV["KRIKRI_FAKE_GEM_DB"] = db
    begin
      yield db
    ensure
      previous_path ? (ENV["PATH"] = previous_path) : ENV.delete("PATH")
      previous_db ? (ENV["KRIKRI_FAKE_GEM_DB"] = previous_db) : ENV.delete("KRIKRI_FAKE_GEM_DB")
      FileUtils.rm_r(bin_dir)
      File.delete(db) if File.exists?(db)
    end
  end

  private GEM_PLAY = <<-YAML
    - name: repro
      hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: gem task
          community.general.gem:
            name: ko-gem
            VERSION_LINE
          register: r
        - name: dump
          ansible.builtin.copy:
            content: |-
              {{ r | to_json }}
            dest: KRIKRI_DUMP_PATH
    YAML

  it "registers a fresh install as name, state, changed" do
    with_gem_shim do
      keys = run_registered_dump(GEM_PLAY.sub("VERSION_LINE", ""))
      keys.must_equal(["name", "state", "changed", "failed"])
    end
  end

  it "registers an already-installed rerun in the same shape" do
    with_gem_shim do |db|
      run_registered_dump(GEM_PLAY.sub("VERSION_LINE", ""))
      File.exists?(db).must_equal(true)
      keys = run_registered_dump(GEM_PLAY.sub("VERSION_LINE", ""))
      keys.must_equal(["name", "state", "changed", "failed"])
    end
  end

  it "echoes version between state and changed when version is requested" do
    with_gem_shim do
      keys = run_registered_dump(GEM_PLAY.sub("VERSION_LINE", "version: \"1.0\""))
      keys.must_equal(["name", "state", "version", "changed", "failed"])
    end
  end

  it "registers an absent no-op and a removal in the same shape" do
    with_gem_shim do |db|
      keys = run_registered_dump(GEM_PLAY.sub("VERSION_LINE", "").sub("gem task", "gem absent no-op").sub("name: ko-gem", "name: ko-gem\n        state: absent"))
      keys.must_equal(["name", "state", "changed", "failed"])

      File.write(db, "ko-gem (1.0)\n")
      keys = run_registered_dump(GEM_PLAY.sub("VERSION_LINE", "").sub("gem task", "gem removal").sub("name: ko-gem", "name: ko-gem\n        state: absent"))
      keys.must_equal(["name", "state", "changed", "failed"])
    end
  end
end
describe "apt_repository plugin result key order (sweep8)" do
  # Real 2.19.11 apt_repository.py has a single success exit
  # exit_json(changed=changed, repo=repo, sources_added=...,
  # sources_removed=..., state=state, diff=diff) - no msg, and `diff`
  # is always present (its source builds diff = [] and only appends
  # under _diff), so the registered order is the same on both the
  # present and absent paths. Live-verified on this host in check mode
  # (unprivileged; the mutating /etc/apt write needs root but shares
  # this one exit). The "Would add repository (check mode)" /
  # "Already ..." msgs were krikri's own - dropped, npm-style.

  private APT_PLAY = <<-YAML
    - name: repro
      hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: apt task
          ansible.builtin.apt_repository:
            repo: "deb [arch=amd64] https://example.invalid/krikri stable main"
            STATE_LINE
          check_mode: true
          register: r
        - name: dump
          ansible.builtin.copy:
            content: |-
              {{ r | to_json }}
            dest: KRIKRI_DUMP_PATH
    YAML

  it "registers an absent no-op as changed, repo, sources_added, sources_removed, state, diff" do
    keys = run_registered_dump(APT_PLAY.sub("STATE_LINE", "state: absent"))
    keys.must_equal(%w[changed repo sources_added sources_removed state diff failed])
  end

  it "registers a check-mode add in the same shape" do
    keys = run_registered_dump(APT_PLAY.sub("STATE_LINE", "state: present"))
    keys.must_equal(%w[changed repo sources_added sources_removed state diff failed])
  end
end
describe "yum_repository plugin result key order (sweep8)" do
  # Real 2.19.11 yum_repository.py exits with a single
  # exit_json(changed=changed, repo=name, state=state, diff=diff), and
  # its diff is the {before_header, before, after_header, after} dict
  # built from the configparser dump UNCONDITIONALLY - not gated on diff
  # mode - so the order is the same on the changed, unchanged and
  # removal paths. No msg key. Live-verified twice: in a Fedora 41
  # container against the real /etc/yum.repos.d, and unprivileged on
  # this host via reposdir: pointed at a temp dir (both engines need no
  # yum/dnf to run the module, only the reposdir to exist).

  private YUM_PLAY = <<-YAML
    - name: repro
      hosts: localhost
      gather_facts: false
      connection: local
      vars:
        ko_reposdir: KRIKRI_REPOSDIR
      tasks:
        - name: yum task
          ansible.builtin.yum_repository:
            name: "ko-repo"
            description: "probe"
            baseurl: "http://example.invalid/ko"
            reposdir: "{{ ko_reposdir }}"
            # STATE_SLOT
          register: r
        - name: dump
          ansible.builtin.copy:
            content: |-
              {{ r | to_json }}
            dest: KRIKRI_DUMP_PATH
    YAML

  private def with_reposdir(&)
    dir = File.tempname("krikri-sweep8-yum")
    Dir.mkdir_p(dir)
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "registers a fresh add as changed, repo, state, diff" do
    with_reposdir do |dir|
      keys = run_registered_dump(YUM_PLAY.gsub("KRIKRI_REPOSDIR", dir).gsub("            # STATE_SLOT\n", ""))
      keys.must_equal(%w[changed repo state diff failed])
    end
  end

  it "registers an unchanged rerun in the same shape" do
    with_reposdir do |dir|
      play = YUM_PLAY.gsub("KRIKRI_REPOSDIR", dir)
      run_registered_dump(play.gsub("            # STATE_SLOT\n", ""))
      keys = run_registered_dump(play.gsub("            # STATE_SLOT\n", ""))
      keys.must_equal(%w[changed repo state diff failed])
    end
  end

  it "registers an already-absent no-op in the same shape" do
    with_reposdir do |dir|
      keys = run_registered_dump(YUM_PLAY.gsub("KRIKRI_REPOSDIR", dir).sub("            # STATE_SLOT", "state: absent"))
      keys.must_equal(%w[changed repo state diff failed])
    end
  end
end
describe "deb822_repository plugin result key order (sweep8)" do
  # Real 2.19.11 deb822_repository.py exits both success paths with
  # exit_json(repo=repo, changed=changed, dest=sources_filename,
  # key_filename=signed_by_filename) - repo FIRST (it is the file
  # content), no msg, and the SAME order on the present and absent
  # exits: the absent one reports repo=None and leaves key_filename at
  # the last probed ext (/etc/apt/keyrings/<slug>.gpg) even when nothing
  # existed. key_filename is a real path only when signed_by was a URL.
  # Live-verified on this host in check mode (unprivileged - the
  # mutating /etc/apt/sources.list.d write needs root but shares this
  # one exit_json per path). The "Would write ..."/"Repository
  # added"/"already absent" msgs were krikri's own - dropped.

  private DEB822_PLAY = <<-YAML
    - name: repro
      hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: deb822 task
          ansible.builtin.deb822_repository:
            name: "korepo-NAME"
            types: [deb]
            uris: ["https://example.invalid/ko"]
            suites: [stable]
            STATE_SLOT
          check_mode: true
          register: r
        - name: dump
          ansible.builtin.copy:
            content: |-
              {{ r | to_json }}
            dest: KRIKRI_DUMP_PATH
    YAML

  it "registers a check-mode add as repo, changed, dest, key_filename" do
    keys = run_registered_dump(DEB822_PLAY.gsub("STATE_SLOT", ""))
    keys.must_equal(%w[repo changed dest key_filename failed])
  end

  it "registers an absent no-op in the same shape" do
    keys = run_registered_dump(DEB822_PLAY.gsub("STATE_SLOT", "state: absent"))
    keys.must_equal(%w[repo changed dest key_filename failed])
  end
end
describe "iptables plugin result key order (sweep8)" do
  # Real 2.19.11 iptables.py builds one args dict at the top of main()
  # - changed, failed, ip_version, table, chain, flush, rule, state,
  # chain_management, wait - and every exit is exit_json(**args), so the
  # order is variant-independent. Note failed sits at position 2: the
  # MODULE puts it in the dict (hence krikri's failed_flag extra),
  # unlike modules whose failed is backfilled by the controller. No msg
  # key. Live-verified through a stateful stub `iptables` binary (no
  # kernel netfilter access unprivileged) driving the real module's own
  # code paths, against the real /usr/sbin/iptables' argv shape.

  serial!

  IPTABLES_SHIM = <<-'SH'
    #!/bin/sh
    DB="${KO_IPT_DB:?}"
    IN="$*"
    case "$IN" in
      *-C*) grep -qxF -- "$IN" "$DB" 2>/dev/null && exit 0 || exit 1;;
      *-D*) grep -vxF -- "$IN" "$DB" > "$DB.tmp" 2>/dev/null; mv "$DB.tmp" "$DB"; exit 0;;
      *-A*|-I*) grep -qxF -- "$IN" "$DB" 2>/dev/null || echo "$IN" >> "$DB"; exit 0;;
      *--version*) echo "iptables v1.8.7 (nf_tables)"; exit 0;;
    esac
    exit 0
    SH

  private def with_iptables_shim(&)
    bin_dir = File.tempname("krikri-sweep8-iptables")
    Dir.mkdir_p(bin_dir)
    binary = File.join(bin_dir, "iptables")
    File.write(binary, IPTABLES_SHIM)
    File.chmod(binary, 0o755)
    db = File.tempname("krikri-sweep8-iptables-db")
    File.delete(db) if File.exists?(db)
    previous_path = ENV["PATH"]?
    previous_db = ENV["KO_IPT_DB"]?
    ENV["PATH"] = "#{bin_dir}:/usr/bin:/bin"
    ENV["KO_IPT_DB"] = db
    begin
      yield db
    ensure
      previous_path ? (ENV["PATH"] = previous_path) : ENV.delete("PATH")
      previous_db ? (ENV["KO_IPT_DB"] = previous_db) : ENV.delete("KO_IPT_DB")
      FileUtils.rm_r(bin_dir)
      File.delete(db) if File.exists?(db)
    end
  end

  private IPTABLES_PLAY = <<-YAML
    - name: repro
      hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: iptables task
          ansible.builtin.iptables:
            chain: INPUT
            protocol: tcp
            destination_port: "8443"
            jump: ACCEPT
            action: append
            STATE_SLOT
          register: r
        - name: dump
          ansible.builtin.copy:
            content: |-
              {{ r | to_json }}
            dest: KRIKRI_DUMP_PATH
    YAML

  it "registers a rule append in the module's own dict order" do
    with_iptables_shim do
      keys = run_registered_dump(IPTABLES_PLAY.gsub("STATE_SLOT", ""))
      keys.must_equal(%w[changed failed ip_version table chain flush rule state chain_management wait])
    end
  end

  it "registers an absent rule removal in the same shape" do
    with_iptables_shim do
      keys = run_registered_dump(IPTABLES_PLAY.gsub("STATE_SLOT", "state: absent"))
      keys.must_equal(%w[changed failed ip_version table chain flush rule state chain_management wait])
    end
  end
end
