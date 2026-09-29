require "../minitest_helper"

# Runs the compiled binary against a real playbook: the deprecation
# rendering lives in ResultDisplay (fed by the mount plugin's result
# marker), which is only reachable end-to-end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Real ansible-core 2.19's _return_formatted deprecates any `warnings`
# key passed to exit_json - ansible.posix.mount does exactly that on
# every successful run. Captured live against 2.19.11 (non-tty,
# ANSIBLE_NOCOLOR=1): the "Deprecation warnings can be disabled" hint
# prints ONCE per run before the first [DEPRECATION WARNING] line, the
# deprecation line itself dedups per run, and neither appears on stdout.
describe "ansible.posix.mount's exit_json warnings deprecation display" do
  it "prints the hint once and the deprecation once for two successful mount tasks" do
    fstab = PluginSpecHelper.tmp_path("mount-deprecation.fstab")
    File.delete(fstab) if File.exists?(fstab)
    playbook = File.tempname("mount-deprecation", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - ansible.posix.mount:
              path: /mnt/dep-one
              src: /dev/sdb1
              fstype: ext4
              state: absent
              fstab: #{fstab}
          - ansible.posix.mount:
              path: /mnt/dep-two
              src: /dev/sdb1
              fstype: ext4
              state: absent
              fstab: #{fstab}
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr.to_s.must_equal(
      "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.\n" \
      "[DEPRECATION WARNING]: Passing `warnings` to `exit_json` or `fail_json` is deprecated. " \
      "This feature will be removed from ansible-core version 2.23. Use `AnsibleModule.warn` instead.\n")
    stdout.to_s.wont_include("DEPRECATION")
    stdout.to_s.must_include("ok=2")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "prints nothing on stderr when every mount task fails (real fail_json passes no args)" do
    playbook = File.tempname("mount-deprecation-fail", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - ansible.posix.mount:
              path: /mnt/dep-fail
              state: present
            ignore_errors: true
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr.to_s.must_equal("")
    stdout.to_s.must_include("fatal: [localhost]: FAILED!")
    status.success?.must_equal(true)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
