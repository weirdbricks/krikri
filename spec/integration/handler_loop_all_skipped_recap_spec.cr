require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook, since the bug lives in
# the looped-handler aggregate booking (#record_handler_result's view of
# #execute_handler_loop's return value), not in anything a unit spec
# against a single method can exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a looped handler whose every item is skipped by when:" do
  it "books the handler as skipped=1 in the recap (not ok=1), with a bare trailing skipping: line" do
    # Real bug found benchmarking round970454's robertdebock.dovecot on
    # Ubuntu: its "Copy sample configuration" handler loops over example
    # config files under a `when: ansible_distribution == "Archlinux"`
    # gate, so on Ubuntu every item skips. Krikri aggregated that to a
    # changed:false/already_displayed result with no "skipped" flag, so
    # the recap counted the handler as ok - finishing ok=9/skipped=1
    # where real ansible-playbook (2.19.11) finishes ok=8/skipped=2.
    # Real Ansible also prints one bare trailing
    # "skipping: [host]" line after the per-item skip lines.
    src_dir = File.tempname("handler-loop-all-skipped")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "handlers"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: trigger it
        debug:
          msg: trigger
        changed_when: true
        notify: sample handler
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "handlers", "main.yml"), <<-YAML)
      - name: sample handler
        debug:
          msg: "running {{ item }}"
        when: false
        loop:
          - 1
          - 2
          - 3
        loop_control:
          label: "{{ item }}"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    # Recap: gathering-free play with one changed trigger task ->
    # ok=1 (the trigger, which counts as ok AND changed), skipped=1
    # (the handler). The handler must NOT appear in ok.
    output.to_s.should match(/ok=1\s+changed=1\s+unreachable=0\s+failed=0\s+skipped=1/)
    # Per-item skip lines exist, plus the bare task-level one.
    output.to_s.should match(/skipping: \[localhost\] => \(item=/)
    output.to_s.should match(/skipping: \[localhost\]\n/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
