require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook: the deprecation
# rendering lives in ResultDisplay (fed by a plugin's result marker),
# which is only reachable end-to-end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# ansible.posix 2.1.x's mount.py passes its `warnings` list to the module's
# exit_json call on every success (args always carries warnings=[]), so
# ansible-core's _return_formatted deprecates the kwarg and real prints
# the line below (issue #1027, live-verified vs 2.21.6 + ansible.posix
# 2.1.0 - the tree this engine's controller resolves). ansible.posix 2.2.0
# warns through AnsibleModule.warn instead and prints no such line (issue
# #906's 2.2.x env).
#
# The MODULE'S IMPORT deprecations ride every result too: the installed
# ansible.posix tree still imports `to_bytes, to_native` from the
# deprecated ansible.module_utils._text path (mount.py:229), so a run
# against ansible-core 2.21.6 emits the one-time hint plus one line per
# imported name, and a registered result carries both entries (issue
# #1000, live-verified).
private MOUNT_WARNINGS_DEPRECATION_LINE = "Passing `warnings` to `exit_json` or `fail_json` is deprecated. " \
                                          "This feature will be removed from ansible-core version 2.23. " \
                                          "Use `AnsibleModule.warn` instead."
private MOUNT_UTILS_TEXT_LINES = [
  "Importing 'to_bytes' from 'ansible.module_utils._text' is deprecated. " \
  "This feature will be removed from ansible-core version 2.24. " \
  "Use ansible.module_utils.common.text.converters instead.",
  "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
  "This feature will be removed from ansible-core version 2.24. " \
  "Use ansible.module_utils.common.text.converters instead.",
]

describe "ansible.posix.mount's exit_json warnings deprecation display" do
  it "prints the import deprecations and the exit_json warnings deprecation for two successful mount tasks" do
    fstab = PluginSpecHelper.tmp_path("mount-warnings-deprecation.fstab")
    File.delete(fstab) if File.exists?(fstab)
    playbook = File.tempname("mount-warnings-deprecation", ".yml")
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
    err.scan("[DEPRECATION WARNING]: #{MOUNT_WARNINGS_DEPRECATION_LINE}").size.must_equal(1)
    MOUNT_UTILS_TEXT_LINES.each do |line|
      err.scan("[DEPRECATION WARNING]: #{line}").size.must_equal(1)
    end
    # ansible records the module's import deprecations before the
    # exit_json-kwargs one, and the console prints them in that order.
    import_pos = err.index!(MOUNT_UTILS_TEXT_LINES[1])
    warnings_pos = err.index!(MOUNT_WARNINGS_DEPRECATION_LINE)
    (import_pos < warnings_pos).must_equal(true)
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
    # fail_json passes msg only - no `warnings` kwarg for
    # _return_formatted to deprecate (live-verified vs 2.21.6 +
    # ansible.posix 2.1.0).
    err.wont_include("Passing `warnings` to `exit_json` or `fail_json` is deprecated.")
    MOUNT_UTILS_TEXT_LINES.each do |line|
      err.scan("[DEPRECATION WARNING]: #{line}").size.must_equal(1)
    end
    stdout.to_s.must_include("fatal: [localhost]: FAILED!")
    status.success?.must_equal(true)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # The other side of the 2.1.x-vs-2.2.x split (issue #1060): with an
  # ansible.posix 2.2.x tree on the controller, real ansible prints NO
  # deprecation at all for a mount task - the 2.2.x mount.py warns
  # through AnsibleModule.warn and takes to_bytes/to_native from
  # `common.text.converters`, so neither the exit_json `warnings`
  # deprecation nor the _text import pair exists there (live-verified
  # vs 2.21.6 + ansible.posix 2.2.2). krikri printed the 2.1.x set
  # anyway because it modeled one module line unconditionally; the
  # executor now pins the resolved release on the wire
  # (build_plugin_config's `collection_version` field), which this
  # end-to-end run is the only cover for.
  it "prints no deprecation lines when the controller resolves an ansible.posix 2.2.x tree" do
    root = PluginSpecHelper.tmp_path("posix-2.2.x-tree")
    posix = File.join(root, "ansible_collections", "ansible", "posix")
    FileUtils.mkdir_p(File.join(posix, "plugins", "modules"))
    File.write(File.join(posix, "MANIFEST.json"),
      %({"collection_info": {"namespace": "ansible", "name": "posix", "version": "2.2.2"}}))
    # The FQCN only has to RESOLVE for the playbook to load - krikri
    # runs its own native mount plugin, never this file.
    File.write(File.join(posix, "plugins", "modules", "mount.py"), "# fixture module\n")

    fstab = PluginSpecHelper.tmp_path("mount-release-2.2.fstab")
    File.delete(fstab) if File.exists?(fstab)
    playbook = File.tempname("mount-release-2.2", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - ansible.posix.mount:
              path: /mnt/rel-two-two
              src: /dev/sdb1
              fstype: ext4
              state: absent
              fstab: #{fstab}
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr,
      env: ENV.to_h.merge({"ANSIBLE_COLLECTIONS_PATH" => root}))

    err = stderr.to_s
    err.wont_include("[DEPRECATION WARNING]")
    err.wont_include("Deprecation warnings can be disabled")
    stdout.to_s.wont_include("DEPRECATION")
    stdout.to_s.must_include("ok=1")
    status.success?.must_equal(true)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
