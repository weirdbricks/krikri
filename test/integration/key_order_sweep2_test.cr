require "../minitest_helper"
require "file_utils"

# Registered-result key orders for the cron/cronvar/git/package_facts/
# service_facts/sudoers/systemd/timezone plugins plus the
# normalize_module_result warnings tail, pinned to the orders
# live-verified against real ansible-core 2.19.11 by registering each
# module's result and dumping `{{ r | to_json }}` (the -v dump sorts
# alphabetically, so the order is only observable programmatically).
#
# Live-verification constraints on this dev box (no passwordless sudo):
# every shape here was captured either in real's check mode (systemd,
# timezone - whose registered shape is identical for changed and
# unchanged: name, changed, status, [enabled,] state, failed /
# changed, diff, failed) or through genuinely unprivileged real runs
# (cron/cronvar against the invoking user's own crontab, git against a
# local file:// repo, package_facts/service_facts/sudoers with the
# module's own temp-path parameters). user/group/authorized_key could
# NOT be verified this way (their registered shapes need root or a
# writable ~/.ssh) and carry no pin.
#
# krikri-only keys (msg and echoed params real's module does not return)
# trail the pinned keys; the assertions below pin krikri's full
# registered order so a later edit cannot silently reshuffle the shared
# keys relative to real's verified one.
#
# pip's changed path was verified live too (changed, cmd, name, version,
# state, requirements, virtualenv, stdout, stderr, stdout_lines,
# stderr_lines, failed - unchanged identical) but has no regression test
# here per repo convention: it needs a real pip install into a venv.
#
# The user/systemd `warnings` tail that normalize_module_result now
# re-appends AFTER the failed/changed backfill was verified through
# real's find module (Skipped-path warning): registered find with a
# skipped path runs files, changed, msg, matched, examined,
# skipped_paths, failed, warnings - warnings last, after the backfilled
# failed.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Same harness as key_order_sweep_test.cr (distinct name so the two
# files can coexist in the generated minitest entrypoint): runs a
# playbook whose final task copies `{{ r | to_json }}` into a file, then
# returns the dumped object's key order.
private def run_registered_dump2(yaml : String) : Array(String)
  dump = PluginSpecHelper.tmp_path("key-order-dump2.json")
  playbook = File.tempname("key-order-sweep2", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  JSON.parse(File.read(dump)).as_h.keys
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "cron plugin result key order" do
  it "registers jobs, envs, changed first (real 2.19.11: jobs, envs, changed, failed, changed/unchanged identical)" do
    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - cron:
              name: krikri-key-order-probe
              minute: "7"
              job: "/bin/true"
            check_mode: true
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.first(3).must_equal(["jobs", "envs", "changed"])
    keys.last.must_equal("failed")
  end
end

describe "cronvar plugin result key order" do
  it "registers vars, changed first (real 2.19.11: vars, changed, failed, changed/unchanged identical)" do
    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - cronvar:
              name: KRIKRI_KEY_ORDER_PROBE
              value: "x"
            check_mode: true
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.first(2).must_equal(["vars", "changed"])
    keys.last.must_equal("failed")
  end
end

describe "git plugin result key order" do
  it "registers changed, before, after on a fresh clone (real 2.19.11: changed, before, after, failed)" do
    base = PluginSpecHelper.tmp_path("git-order-#{Random::Secure.hex(4)}")
    repo = File.join(base, "repo")
    clone = File.join(base, "clone")
    FileUtils.mkdir_p(repo)
    Process.run("git", ["init", "-q", repo], output: Process::Redirect::Close, error: Process::Redirect::Close)
    File.write(File.join(repo, "f"), "x")
    Process.run("git", ["-c", "user.email=a@b", "-c", "user.name=a", "add", "f"], output: Process::Redirect::Close, error: Process::Redirect::Close, chdir: repo)
    Process.run("git", ["-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "init"], output: Process::Redirect::Close, error: Process::Redirect::Close, chdir: repo)

    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - git:
              repo: #{repo}
              dest: #{clone}
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.first(3).must_equal(["changed", "before", "after"])
    keys.last.must_equal("failed")
  ensure
    FileUtils.rm_r(base) if base && Dir.exists?(base)
  end

  it "keeps the same shared order on an idempotent update (real 2.19.11: changed, before, remote_url_changed, after, failed)" do
    base = PluginSpecHelper.tmp_path("git-order-#{Random::Secure.hex(4)}")
    repo = File.join(base, "repo")
    clone = File.join(base, "clone")
    FileUtils.mkdir_p(repo)
    Process.run("git", ["init", "-q", repo], output: Process::Redirect::Close, error: Process::Redirect::Close)
    File.write(File.join(repo, "f"), "x")
    Process.run("git", ["-c", "user.email=a@b", "-c", "user.name=a", "add", "f"], output: Process::Redirect::Close, error: Process::Redirect::Close, chdir: repo)
    Process.run("git", ["-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "init"], output: Process::Redirect::Close, error: Process::Redirect::Close, chdir: repo)
    Process.run("git", ["clone", "-q", repo, clone], output: Process::Redirect::Close, error: Process::Redirect::Close)

    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - git:
              repo: #{repo}
              dest: #{clone}
              update: true
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.first(3).must_equal(["changed", "before", "after"])
    keys.last.must_equal("failed")
  ensure
    FileUtils.rm_r(base) if base && Dir.exists?(base)
  end
end

describe "package_facts plugin result key order" do
  it "registers ansible_facts, failed, changed (real 2.19.11: ansible_facts, failed, changed - exit_json passes no changed)" do
    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - package_facts:
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.first.must_equal("ansible_facts")
    keys.last(2).must_equal(["failed", "changed"])
    # Full shape - real has NO msg key (a krikri-only "Gathered N package
    # facts" msg used to sit between ansible_facts and failed).
    keys.must_equal(["ansible_facts", "failed", "changed"])
  end
end

describe "service_facts plugin result key order" do
  it "registers ansible_facts, failed, changed (real 2.19.11: ansible_facts, failed, changed - exit_json passes no changed)" do
    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - service_facts:
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.first.must_equal("ansible_facts")
    keys.last(2).must_equal(["failed", "changed"])
  end
end

describe "sudoers plugin result key order" do
  it "registers changed first (real 2.19.11: changed, failed - the module's wire is just {changed})" do
    dir = PluginSpecHelper.tmp_path("sudoers-order-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.general.sudoers:
              name: krikri-key-order-probe
              user: krikri-probe-user
              commands: [ALL]
              sudoers_path: #{dir}
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.first.must_equal("changed")
    keys.last.must_equal("failed")
  ensure
    FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
  end
end

describe "systemd plugin result key order" do
  it "registers name, changed, status, enabled, state (real 2.19.11 check mode: name, changed, status, enabled, state, failed)" do
    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - systemd:
              name: cron.service
              state: started
              enabled: true
            check_mode: true
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.first(5).must_equal(["name", "changed", "status", "enabled", "state"])
    keys.last.must_equal("failed")
  end
end

describe "timezone plugin result key order" do
  it "registers changed, diff (real 2.19.11: changed, diff, failed, changed/unchanged identical)" do
    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - timezone:
              name: Europe/Berlin
            check_mode: true
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.first(2).must_equal(["changed", "diff"])
    keys.last.must_equal("failed")
  end
end

describe "normalize_module_result warnings tail" do
  it "re-appends module warnings after the failed/changed backfill (real 2.19.11 find: skipped_paths, failed, warnings)" do
    keys = run_registered_dump2(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - find:
              paths: ["/etc/ssl", "/etc/hostname"]
            register: r
          - copy:
              content: |-
                {{ r | to_json }}
              dest: KRIKRI_DUMP_PATH
      YAML
    keys.must_equal(["files", "changed", "msg", "matched", "examined", "skipped_paths", "failed", "warnings"])
  end
end
