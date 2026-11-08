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
# no "Passing `warnings` to `exit_json`" line.
#
# The MODULE'S IMPORT deprecations are a separate question and do print:
# the installed ansible.posix tree still imports `to_bytes, to_native` from
# the deprecated ansible.module_utils._text path (mount.py:229), so a run
# against ansible-core 2.21.6 emits the one-time hint plus one line per
# imported name, and a registered result carries both entries (issue #1000,
# live-verified). What this spec is about - the exit_json kwargs
# deprecation - stays absent, which is the assertion that matters here.
private MOUNT_UTILS_TEXT_LINES = [
  "Importing 'to_bytes' from 'ansible.module_utils._text' is deprecated. " \
  "This feature will be removed from ansible-core version 2.24. " \
  "Use ansible.module_utils.common.text.converters instead.",
  "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
  "This feature will be removed from ansible-core version 2.24. " \
  "Use ansible.module_utils.common.text.converters instead.",
]

describe "ansible.posix.mount's exit_json warnings deprecation display" do
  it "prints only the module's import deprecations for two successful mount tasks" do
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

    err = stderr.to_s
    err.wont_include("Passing `warnings` to `exit_json` or `fail_json` is deprecated.")
    MOUNT_UTILS_TEXT_LINES.each do |line|
      err.scan("[DEPRECATION WARNING]: #{line}").size.must_equal(1)
    end
    # Two mount tasks, one Display dedup per distinct line.
    err.scan("[WARNING]: Deprecation warnings can be disabled").size.must_equal(1)
    stdout.to_s.wont_include("DEPRECATION")
    stdout.to_s.must_include("ok=2")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "prints only the module's import deprecations when every mount task fails" do
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

    err = stderr.to_s
    err.wont_include("Passing `warnings` to `exit_json` or `fail_json` is deprecated.")
    MOUNT_UTILS_TEXT_LINES.each do |line|
      err.scan("[DEPRECATION WARNING]: #{line}").size.must_equal(1)
    end
    stdout.to_s.must_include("fatal: [localhost]: FAILED!")
    status.success?.must_equal(true)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
