require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook, since this bug is in
# the executor's controller-side handler dispatch, not something a unit
# spec against a single method can exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a looped handler with a per-item when: referencing item" do
  it "evaluates when: once per iteration (with item bound), not once before the loop with no item at all" do
    # Real bug found benchmarking round168's geerlingguy.ssh-chroot-jail
    # on Ubuntu 22.04. Its own "add binary libs via l2chroot" handler:
    #   command: "{{ l2chroot_path }} {{ item.bin | default(item) }}"
    #   when: item.l2chroot is not defined or item.l2chroot
    #   with_items: "{{ some_bins_list }}"
    # The when: was evaluated ONCE, before the loop even resolved (so
    # `item` was completely unbound) - `item.l2chroot is not defined`
    # was trivially true regardless of any individual item's real
    # value, so EVERY item ran unconditionally, including ones whose own
    # `l2chroot: false` flag should have skipped them.
    src_dir = File.tempname("handler-loop-when-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "handlers"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "defaults"))
    File.write(File.join(src_dir, "roles", "myrole", "defaults", "main.yml"), <<-YAML)
      some_bins_list:
        - /bin/cp
        - bin: /usr/bin/which
          l2chroot: false
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: trigger it
        debug:
          msg: trigger
        changed_when: true
        notify: add binary libs via l2chroot
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "handlers", "main.yml"), <<-YAML)
      - name: add binary libs via l2chroot
        debug:
          msg: "processing {{ item.bin | default(item) }}"
        when: item.l2chroot is not defined or item.l2chroot
        with_items: "{{ some_bins_list }}"
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
    output.to_s.should contain("processing /bin/cp")
    output.to_s.should contain("skipping:")
    output.to_s.should contain("which")
    output.to_s.should_not contain("processing /usr/bin/which")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
