require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about the
# LOOPED executor path's per-item skip handling in
# TaskExecutor#finish_looped_task - private, not reachable from a unit
# spec without constructing a whole TaskExecutor. The single-task,
# non-looped creates:-skip is already covered by spec/integration/
# unarchive_spec.cr; this file exists purely for the looped path's
# display + recap accounting.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private TMP_DIR = File.join(PROJECT_ROOT, "spec", "tmp", "unarchive-loop-creates-skip")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("unarchive-loop-creates-skip-spec", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(File.join(TMP_DIR, "src"))
  File.write(File.join(TMP_DIR, "src", "payload.txt"), "payload")
  `tar czf #{File.join(TMP_DIR, "archive.tar.gz")} -C #{File.join(TMP_DIR, "src")} payload.txt`
end

private def fresh_dest(name : String) : String
  path = File.join(TMP_DIR, name)
  FileUtils.rm_rf(path) if Dir.exists?(path)
  Dir.mkdir_p(path)
  path
end

describe "looped unarchive with per-item creates: skip (executor_loops#finish_looped_task)" do
  it "counts the whole task as skipped=1 (not ok=1) when EVERY item's creates: file already exists, printing per-item skipping: lines plus the bare trailing one" do
    # Real bug found via jjahrik.nerd_fonts round 813005 plus a live
    # repro against real ansible-playbook (ansible-core 2.19): the
    # looped executor path ignored a plugin's own per-item
    # "skipped": true (unarchive's creates:-already-exists result),
    # printing "ok:" per item and booking the task in ok= instead of
    # skipped=. Real Ansible prints one skipping: line per item, THEN
    # one bare trailing `skipping: [host]` line (same as the
    # genuinely-empty-loop case), and recaps skipped=1.
    dest = fresh_dest("all-skip")
    File.write(File.join(dest, "marker1.txt"), "")
    File.write(File.join(dest, "marker2.txt"), "")

    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: unarchive loop, all creates satisfied
            ansible.builtin.unarchive:
              src: #{File.join(TMP_DIR, "archive.tar.gz")}
              dest: #{dest}
              remote_src: true
              creates: "#{dest}/{{ item.creates }}"
            loop:
              - { name: one, creates: marker1.txt }
              - { name: two, creates: marker2.txt }
      YAML

    status.success?.should be_true
    output.scan(/skipping: \[localhost\] => \(item=/).size.should eq(2)
    output.should contain("skipping: [localhost]\n")
    output.should contain("ok=0")
    output.should contain("skipped=1")
  end

  it "shows skipping: for the creates:-satisfied item and changed: for the rest, with the registered aggregate still holding all items" do
    # The mixed-shape half of the same gap: a partially-skipped loop
    # must book its recap ONLY from the items that actually ran (real
    # Ansible adds no separate skipped= bump when at least one item
    # executed), while register:'d .results still exposes the skipped
    # items alongside the executed ones.
    dest = fresh_dest("mixed")
    File.write(File.join(dest, "marker1.txt"), "")

    status, output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: unarchive loop, mixed creates
            ansible.builtin.unarchive:
              src: #{File.join(TMP_DIR, "archive.tar.gz")}
              dest: #{dest}
              remote_src: true
              creates: "#{dest}/{{ item.creates }}"
            register: unarchive_result
            loop:
              - { name: one, creates: marker1.txt }
              - { name: two, creates: marker2.txt }
          - name: assert
            ansible.builtin.assert:
              that:
                - unarchive_result.results | length == 2
                - unarchive_result.results[0].skipped == true
                - unarchive_result.results[1].changed == true
      YAML

    status.success?.should be_true
    output.scan(/skipping: \[localhost\] => \(item=/).size.should eq(1)
    output.should contain("changed: [localhost] => (item=")
    output.should contain("All assertions passed")
    output.should contain("ok=2")
    output.should contain("changed=1")
    output.should contain("skipped=0")
  end
end
