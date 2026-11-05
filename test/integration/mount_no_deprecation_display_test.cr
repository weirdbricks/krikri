require "../minitest_helper"

# Runs the compiled binary against a real playbook: the deprecation
# rendering lives in ResultDisplay (fed by a plugin's result marker),
# which is only reachable end-to-end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# ansible.posix 2.2.0 stopped passing its `warnings` list to exit_json
# (mount.py warns through AnsibleModule.warn now), so ansible-core's
# _return_formatted has nothing to deprecate on a successful mount:
# running the same tasks against 2.20.1 with ansible.posix 2.2.2 prints
# neither the "Deprecation warnings can be disabled" hint nor a
# [DEPRECATION WARNING] line.
describe "ansible.posix.mount's exit_json warnings deprecation display" do
  it "prints nothing on stderr for two successful mount tasks (ansible.posix 2.2.0 dropped the warnings kwarg)" do
    fstab = PluginSpecHelper.tmp_path("mount-no-deprecation.fstab")
    File.delete(fstab) if File.exists?(fstab)
    playbook = File.tempname("mount-no-deprecation", ".yml")
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

    stderr.to_s.must_equal("")
    stdout.to_s.wont_include("DEPRECATION")
    stdout.to_s.must_include("ok=2")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "prints nothing on stderr when every mount task fails" do
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
