require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the trailing bare skip
# for an all-items-skipped `loop:` include_vars: only shows end to end,
# where the executor's looped include_vars path decides between printing
# per-item lines and the aggregate closer.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "include_vars: with loop: skipped by a false when: on every item" do
  it "prints one per-item skip line per loop item plus the bare trailing skip line" do
    # Real bug confirmed with a minimal repro against ansible-core
    # 2.19.11 (linux-system-roles.sudo's "Set platform/version specific
    # variables" shape, issue #559): a `loop:` include_vars: whose
    # per-item when: is false for every item must print one
    # `skipping: [localhost] => (item=...)` line per item PLUS the bare
    # trailing `skipping: [localhost]` line real's default callback
    # closes every looped task whose results carry 'results' with.
    # krikri used to print only the per-item lines and swallow the
    # closer. The item files are never touched - the conditional fails
    # before the path resolves - so they need not exist.
    src_dir = PluginSpecHelper.tmp_path("loop-when-false-skip")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Load a variable file
            include_vars: "{{ item }}"
            loop:
              - vars/debian-12.yml
              - vars/debian-11.yml
              - vars/redhat-9.yml
              - vars/redhat-8.yml
            when: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    lines = output.to_s.lines
    # One item-labelled skip per loop item (real's `=> (item=...) `
    # suffix keeps its trailing space - the -v dump slot, empty here).
    lines.count(&.rstrip.ends_with?("=> (item=vars/debian-12.yml)")).must_equal(1)
    lines.count(&.rstrip.ends_with?("=> (item=vars/redhat-8.yml)")).must_equal(1)
    lines.count(&.includes?("=> (item=")).must_equal(4)
    # Exactly one bare trailing line, AFTER the item lines.
    lines.count(&.==("skipping: [localhost]")).must_equal(1)
    item_index = lines.index(&.includes?("=> (item="))
    bare_index = lines.index(&.==("skipping: [localhost]"))
    (bare_index && item_index && bare_index > item_index).must_equal(true)
    output.to_s.must_include("skipped=1")
    output.to_s.wont_include("ok: [localhost]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "matches real's -v shape: the trailing line carries the All items skipped dump" do
    # Real's -v trailing line closes with the all-items-skipped
    # aggregate dump (verified against ansible-core 2.19.11), not a
    # bare line.
    src_dir = PluginSpecHelper.tmp_path("loop-when-false-verbose")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Load a variable file
            include_vars: "{{ item }}"
            loop:
              - vars/one.yml
              - vars/two.yml
            when: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-v", "-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include(%(skipping: [localhost] => {"changed": false, "msg": "All items skipped"}))
    lines = output.to_s.lines
    lines.count(&.includes?(%({"changed": false, "msg": "All items skipped"}))).must_equal(1)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
