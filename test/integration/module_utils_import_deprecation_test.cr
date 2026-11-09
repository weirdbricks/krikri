require "../minitest_helper"
require "file_utils"

# The deprecated ansible.module_utils import warnings ansible-core 2.21
# raises while a collection module's payload imports, for the modules this
# engine implements without python (issue #1000).
#
# ansible-core 2.21 serves `ansible.module_utils._text` as a shim whose
# __getattr__ deprecates each imported name (one line per name, in the
# module's own import order, once per run behind the one-time "can be
# disabled" hint) and `ansible.module_utils.common._collections_compat`
# deprecates itself on import, so real prints them wherever that import
# happens - on a run of ansible-core 2.21.6 plus the installed ansible.posix
# tree, a native plugin result here must carry the same console lines and
# the same registered `deprecations` entries.
describe "deprecated ansible.module_utils import warnings from native plugins" do
  it "carries mount's to_bytes/to_native pair on a module result" do
    # ansible.posix.mount imports `to_bytes, to_native` from `_text`
    # (mount.py:229) before any validation runs, so a fail_json exit
    # carries them too - the same place krikri's plugin binary lands when
    # the args are missing.
    result = PluginSpecHelper.run("mount", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["_ansible_core_deprecations"].as_a.map(&.as_s).must_equal([
      "Importing 'to_bytes' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead.",
      "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead.",
    ])
    result["deprecations"].as_a.must_equal([
      JSON.parse({
        "msg"             => "Importing 'to_bytes' from 'ansible.module_utils._text' is deprecated.",
        "collection_name" => "ansible.builtin",
        "version"         => "2.24",
        "deprecator"      => {"resolved_name" => "ansible.builtin", "type" => nil},
      }.to_json),
      JSON.parse({
        "msg"             => "Importing 'to_native' from 'ansible.module_utils._text' is deprecated.",
        "collection_name" => "ansible.builtin",
        "version"         => "2.24",
        "deprecator"      => {"resolved_name" => "ansible.builtin", "type" => nil},
      }.to_json),
    ])
  end

  it "carries acl's single to_native import deprecation" do
    # acl.py:150 imports to_native alone, so the console answers exactly
    # one line for it.
    result = PluginSpecHelper.run("acl", {} of String => String)

    result["_ansible_core_deprecations"].as_a.map(&.as_s).must_equal([
      "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead.",
    ])
    result["deprecations"].as_a.size.must_equal(1)
    result["deprecations"][0]["msg"].as_s.must_equal(
      "Importing 'to_native' from 'ansible.module_utils._text' is deprecated.")
  end

  # The table models the ansible.posix 2.1.x sources: 2.2.x moved every
  # catalogued module onto `common.text.converters`, whose imports
  # deprecate nothing, so a run against a 2.2.x tree prints no import
  # lines at all (issue #1060 - krikri printed the 2.1.x pair against a
  # 2.2.x tree). The executor pins the release through the wire config's
  # `collection_version` field.
  it "carries no import deprecations when the resolved collection release is 2.2.x" do
    result = PluginSpecHelper.run("mount", {} of String => String, collection_version: "2.2.2")

    result["failed"].as_bool.must_equal(true)
    result.as_h.has_key?("deprecations").must_equal(false)
    result.as_h.has_key?("_ansible_core_deprecations").must_equal(false)
  end
end

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# The same warnings end-to-end, where their position in the output is what
# matters: ansible loads a controller-side ACTION plugin lazily, right
# before that task's banner (a `when:`-skipped synchronize still warns
# there), and the module payload's own imports warn inside the task,
# before the status line.
describe "deprecated ansible.module_utils import warnings in play output" do
  it "prints synchronize's action-plugin imports before its own payload's imports, once per line" do
    root = PluginSpecHelper.tmp_path("module-utils-import-deprecation")
    Dir.mkdir_p(File.join(root, "src"))
    Dir.mkdir_p(File.join(root, "dest"))
    File.write(File.join(root, "src", "payload.txt"), "hello\n")
    playbook = File.join(root, "sync.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: sync one
            ansible.posix.synchronize:
              src: #{root}/src/
              dest: #{root}/dest/
            register: r1
          - name: sync two
            ansible.posix.synchronize:
              src: #{root}/src/
              dest: #{root}/dest/
            register: r2
          - name: dump
            debug:
              msg: "{{ r1.deprecations | length }} {{ r2.deprecations | length }}"
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    err = stderr.to_s

    status.success?.must_equal(true)
    err.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    # The action plugin loads first: its two imports precede the module
    # payload's pair in the same stderr stream.
    action_text = "Importing 'to_text' from 'ansible.module_utils._text' is deprecated. " \
                  "This feature will be removed from ansible-core version 2.24. " \
                  "Use ansible.module_utils.common.text.converters instead."
    compat_text = "The `ansible.module_utils.common._collections_compat` module is deprecated. " \
                  "This feature will be removed from ansible-core version 2.24. " \
                  "Use `collections.abc` from the Python standard library instead."
    to_bytes_text = "Importing 'to_bytes' from 'ansible.module_utils._text' is deprecated. " \
                    "This feature will be removed from ansible-core version 2.24. " \
                    "Use ansible.module_utils.common.text.converters instead."
    to_native_text = "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
                     "This feature will be removed from ansible-core version 2.24. " \
                     "Use ansible.module_utils.common.text.converters instead."
    err.must_include(action_text)
    err.must_include(compat_text)
    err.must_include(to_bytes_text)
    err.must_include(to_native_text)
    action_idx = err.index(action_text)
    compat_idx = err.index(compat_text)
    payload_idx = err.index(to_bytes_text)
    flunk("expected the action plugin's imports before the payload's") unless action_idx && compat_idx && payload_idx &&
                                                                              action_idx < payload_idx && compat_idx < payload_idx
    # Display dedups every distinct line, so the second synchronize task
    # adds nothing - real answers each imported name once per run.
    err.scan(action_text).size.must_equal(1)
    err.scan(to_bytes_text).size.must_equal(1)
    # Only the module payload's imports land on the registered result: the
    # action plugin's own imports are controller-side console output real
    # never attaches to a result.
    stdout.to_s.must_include("ok: [localhost] => {")
    stdout.to_s.must_include("2 2")
  end
end
