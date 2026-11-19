require "../minitest_helper"
require "file_utils"
require "../../src/krikri/module_utils_deprecations"

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

  it "carries no docker_container _collections_compat deprecation at the pinned release (issue #1318)" do
    # The captured community.docker release (5.2.1) has migrated off the
    # deprecated path, so real prints nothing for this task and neither
    # may this engine - whatever a fixture tree planted via
    # ANSIBLE_COLLECTIONS_PATH would have said under the old runtime scan.
    root = PluginSpecHelper.tmp_path("module-utils-docker-decoy")
    base = File.join(root, "ansible_collections", "community", "docker", "plugins")
    FileUtils.mkdir_p(File.join(base, "modules"))
    FileUtils.mkdir_p(File.join(base, "module_utils"))
    File.write(File.join(base, "modules", "docker_container.py"),
      "from ansible_collections.community.docker.plugins.module_utils.common_api import AnsibleDockerClient\n")
    File.write(File.join(base, "module_utils", "common_api.py"),
      "from ansible.module_utils.common._collections_compat import Mapping, Sequence\n")

    result = PluginSpecHelper.run("docker_container", {} of String => String,
      env: {"ANSIBLE_COLLECTIONS_PATH" => root})

    result["failed"].as_bool.must_equal(true)
    result["deprecations"]?.must_be_nil
    result["_ansible_core_deprecations"]?.must_be_nil
  end

  it "keeps docker_network_info's client-construction failure clean at the pinned release (issue #1340)" do
    # A bogus api_version fails inside the client construction, i.e. in a
    # rescued failure exit rather than through #execute's return. The
    # captured community.docker release (5.2.1) no longer imports
    # `_collections_compat`, so real prints no import deprecation above
    # that error and registers none - and the decoy fixture tree below
    # (which would have answered the other way under the old runtime
    # scan) changes nothing.
    root = PluginSpecHelper.tmp_path("module-utils-docker-network-info-compat")
    base = File.join(root, "ansible_collections", "community", "docker", "plugins")
    FileUtils.mkdir_p(File.join(base, "modules"))
    FileUtils.mkdir_p(File.join(base, "module_utils"))
    File.write(File.join(base, "modules", "docker_network_info.py"),
      "from ansible_collections.community.docker.plugins.module_utils.common_api import AnsibleDockerClient\n")
    File.write(File.join(base, "module_utils", "common_api.py"),
      "from ansible.module_utils.common._collections_compat import Mapping, Sequence\n")

    result = PluginSpecHelper.run("docker_network_info",
      {"name" => "krikri-net", "api_version" => "atoobk"},
      env: {"ANSIBLE_COLLECTIONS_PATH" => root})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error connecting: invalid version number 'atoobk'")
    result["deprecations"]?.must_be_nil
    result["_ansible_core_deprecations"]?.must_be_nil
  end

  it "carries amazon.aws's payload import deprecations where the target sees no collection tree (issue #1199)" do
    # The native ec2_vpc_net_info binary runs on the TARGET, which has no
    # amazon.aws tree to scan, so only the modeled table can reproduce
    # what real bundles from the controller: its payload imports to_native
    # through the shared module_utils chain and to_text from tagging.py
    # (live-verified against 2.21.6 + amazon.aws 10.1.1 - the registered
    # `deprecations` sequence keeps every repeat, the console collapses
    # them by text). An empty collections path is that target shape.
    root = PluginSpecHelper.tmp_path("module-utils-aws-target")
    Dir.mkdir_p(root)
    result = PluginSpecHelper.run("ec2_vpc_net_info", {} of String => String,
      collection_version: "10.1.1", env: {"ANSIBLE_COLLECTIONS_PATH" => root})

    result["failed"].as_bool.must_equal(true)
    native = "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
             "This feature will be removed from ansible-core version 2.24. " \
             "Use ansible.module_utils.common.text.converters instead."
    text = "Importing 'to_text' from 'ansible.module_utils._text' is deprecated. " \
           "This feature will be removed from ansible-core version 2.24. " \
           "Use ansible.module_utils.common.text.converters instead."
    result["_ansible_core_deprecations"].as_a.map(&.as_s).must_equal([native, native, native, native, text, native, text])
    result["deprecations"].as_a.size.must_equal(7)
  end

  it "carries no amazon.aws import deprecations once its resolved release migrated (11.3.0)" do
    root = PluginSpecHelper.tmp_path("module-utils-aws-migrated-target")
    Dir.mkdir_p(root)
    result = PluginSpecHelper.run("ec2_vpc_net_info", {} of String => String,
      collection_version: "11.3.0", env: {"ANSIBLE_COLLECTIONS_PATH" => root})

    result["failed"].as_bool.must_equal(true)
    result["deprecations"]?.must_be_nil
    result["_ansible_core_deprecations"]?.must_be_nil
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

  it "ignores a collection tree planted via ANSIBLE_COLLECTIONS_PATH (issue #1061)" do
    # The pre-redesign engine read the installed mount.py and went silent
    # when it saw the migrated import. krikri's captured payload decides
    # now, so a planted tree carrying the migrated source must not move
    # the answer - the pinned ansible.posix 2.1.x pair still prints.
    root = PluginSpecHelper.tmp_path("module-utils-migrated-fixture")
    modules = File.join(root, "ansible_collections", "ansible", "posix", "plugins", "modules")
    FileUtils.mkdir_p(modules)
    File.write(File.join(modules, "mount.py"),
      "from ansible.module_utils.common.text.converters import to_bytes, to_native\n")

    result = PluginSpecHelper.run("mount", {} of String => String, env: {"ANSIBLE_COLLECTIONS_PATH" => root})

    result["failed"].as_bool.must_equal(true)
    result["_ansible_core_deprecations"].as_a.size.must_equal(2)
    result["deprecations"].as_a.size.must_equal(2)
  end
end

# The deprecated imports come from krikri's OWN baked capture of the
# module payload (collection_runtime_data.cr, generated by
# scripts/gen_collection_runtime_data.py), not from an installed
# collection tree: the same lines print on a remote TARGET, on a
# collection-less controller and on a fully populated one. The specs below
# assert the pinned answers and, more importantly, that pointing the
# collection env at a tree which WOULD have changed them under the old
# scan changes nothing.
describe "module_utils import deprecations come from the baked payload capture" do
  it "carries ansible.posix 2.1.x mount's to_bytes/to_native pair" do
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("ansible.posix.mount").must_equal(["to_bytes", "to_native"])
    # The bare spelling resolves onto the same capture.
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("mount").must_equal(["to_bytes", "to_native"])
    # The engine's own FQCN goes through the builtin-runtime redirect first.
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("ansible.builtin.mount").must_equal(["to_bytes", "to_native"])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_result_entries("ansible.posix.mount").size.must_equal(2)
  end

  it "carries the action plugin's lines in import order from the capture" do
    Krikri::ModuleUtilsDeprecations.action_plugin_text_import_deprecation_texts("synchronize").must_equal([
      "Importing 'to_text' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead.",
      Krikri::ModuleUtilsDeprecations::COLLECTIONS_COMPAT_DEPRECATION_TEXT,
    ])
  end

  it "carries the action plugin's deprecated ansible.errors import ahead of its _text one (issue #1198)" do
    Krikri::ModuleUtilsDeprecations.action_plugin_text_import_deprecation_texts("patch").must_equal([
      "Importing '_AnsibleActionDone' is deprecated. " \
      "This feature will be removed from ansible-core version 2.23. " \
      "Return directly from action plugins instead.",
      "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead.",
    ])
  end

  it "carries containers.podman's module_utils chain pair through the capture (issue #1156)" do
    # podman_container.py itself imports nothing deprecated; the capture
    # follows its module_utils/podman/podman_container_lib.py the way
    # real's own import chain does.
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("containers.podman.podman_container")
      .must_equal(["to_bytes", "to_native"])
  end

  it "carries no _collections_compat event for the captured community.docker release (issue #1318)" do
    # community.docker 5.2.1 (the pinned capture) moved its module_utils
    # off `_collections_compat`, so real warns nothing and neither does
    # this engine - the 4.7.x line's event is no longer modeled, because
    # krikri no longer reads whatever release the controller happens to
    # have.
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("community.docker.docker_container")
      .must_equal([] of String)
  end

  it "keeps the modeled table for a module payload no capture carries" do
    # A name the capture has no real payload for (an invented collection)
    # keeps the hand-modeled pair - the issue #1000 behavior.
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.mount").must_equal(["to_bytes", "to_native"])
  end

  it "models docker_container's _collections_compat event until community.docker 4.8.0 (issue #1318)" do
    # The hand-modeled fallback still honors the release gate for a name
    # the capture does not carry.
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.docker_container", "4.7.0")
      .must_equal([Krikri::ModuleUtilsDeprecations::COLLECTIONS_COMPAT_SYMBOL])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_texts("totally.absent.docker_container", "4.7.0")
      .must_equal([Krikri::ModuleUtilsDeprecations::COLLECTIONS_COMPAT_DEPRECATION_TEXT])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_result_entries("totally.absent.docker_container", "4.7.0")[0]["msg"]
      .as_s.must_equal(Krikri::ModuleUtilsDeprecations::COLLECTIONS_COMPAT_DEPRECATION_MSG)
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.docker_container", "4.8.0")
      .must_equal([] of String)
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.docker_container", "5.2.1")
      .must_equal([] of String)
  end

  it "keeps the modeled podman_container pair until its own migration boundary (issue #1156)" do
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.podman_container")
      .must_equal(["to_bytes", "to_native"])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.podman_container", "1.17.0")
      .must_equal(["to_bytes", "to_native"])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.podman_container", "1.18.2")
      .must_equal(["to_bytes", "to_native"])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.podman_container", "1.19.0")
      .must_equal([] of String)
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.podman_container", "1.21.2")
      .must_equal([] of String)
  end

  it "scopes the 2.2.0 migration gate to ansible.posix (issue #1199)" do
    # amazon.aws 10.x's payload still imports to_native even though its
    # release number is far past ansible.posix's 2.2.0 boundary. The
    # capture keeps no amazon.aws payload (its first installed copy
    # carries no modules), so the hand table models it - gated by the
    # collection, not by the number.
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("amazon.aws.ec2_vpc_net_info", "11.2.0")
      .must_equal(["to_native", "to_native", "to_native", "to_native", "to_text", "to_native", "to_text"])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("amazon.aws.ec2_vpc_net_info", "11.3.0")
      .must_equal([] of String)
  end

  it "scopes the action plugin lookup to the task's own collections (issue #1352)" do
    # Real's action loader only searches the collections a task scopes,
    # while its MODULE loader finds a bare name in every collection - so
    # an unscoped bare name that resolves its module elsewhere still runs
    # through the generic `normal` action plugin and imports no action
    # plugin at all (live-verified vs ansible-core 2.21.6 +
    # kubernetes.core 6.1.0). All three answers come from the baked
    # action-plugin inventory, so a fixture tree cannot move them.
    Krikri::CollectionIndex.action_plugin_in_scope?("k8s", [] of String)
      .must_equal(false)
    Krikri::CollectionIndex.action_plugin_in_scope?("k8s", ["kubernetes.core"])
      .must_equal(true)
    Krikri::CollectionIndex.action_plugin_in_scope?("kubernetes.core.k8s", [] of String)
      .must_equal(true)
    # ansible_builtin_runtime.yml's ACTION routing redirect makes an
    # unscoped bare name load its collection's plugin (a `when:`-skipped
    # bare synchronize/patch task still warns).
    Krikri::CollectionIndex.action_plugin_in_scope?("synchronize", [] of String)
      .must_equal(true)
  end

  it "does not vary with ANSIBLE_COLLECTIONS_PATH (the old installed-payload scan is gone)" do
    # A fixture tree that carries a MIGRATED ansible.posix mount (no
    # _text import) and a _collections_compat-importing community.docker:
    # under the old code both changed the answer. Nothing may move now.
    root = PluginSpecHelper.tmp_path("module-utils-decoy-fixture")
    posix_modules = File.join(root, "ansible_collections", "ansible", "posix", "plugins", "modules")
    FileUtils.mkdir_p(posix_modules)
    File.write(File.join(posix_modules, "mount.py"),
      "from ansible.module_utils.common.text.converters import to_bytes, to_native\n")
    docker_utils = File.join(root, "ansible_collections", "community", "docker", "plugins")
    FileUtils.mkdir_p(File.join(docker_utils, "modules"))
    FileUtils.mkdir_p(File.join(docker_utils, "module_utils"))
    File.write(File.join(docker_utils, "modules", "docker_container.py"),
      "from ansible_collections.community.docker.plugins.module_utils.common_api import AnsibleDockerClient\n")
    File.write(File.join(docker_utils, "module_utils", "common_api.py"),
      "from ansible.module_utils.common._collections_compat import Mapping, Sequence\n")

    begin
      ENV["ANSIBLE_COLLECTIONS_PATH"] = root
      Krikri::CollectionIndex.reset!
      Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("ansible.posix.mount")
        .must_equal(["to_bytes", "to_native"])
      Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("community.docker.docker_container")
        .must_equal([] of String)
    ensure
      ENV.delete("ANSIBLE_COLLECTIONS_PATH")
      Krikri::CollectionIndex.reset!
    end
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

  # synchronize's action plugin returns its own failed dict for a missing
  # src/dest, before it ever reaches _execute_module, so the module payload
  # (whose imports produce the to_bytes/to_native lines) never runs: real
  # prints only the action plugin's own pair and registers no deprecations
  # (live-verified vs ansible-core 2.21.6 + ansible.posix 2.1.0, issue
  # #1306).
  it "prints only the action plugin's imports when synchronize fails before running its module" do
    root = PluginSpecHelper.tmp_path("module-utils-import-deprecation-missing-dest")
    Dir.mkdir_p(root)
    playbook = File.join(root, "sync.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: sync without dest
            ansible.posix.synchronize:
              src: #{root}/src/
            ignore_errors: true
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    err = stderr.to_s

    status.success?.must_equal(true)
    err.must_include("Importing 'to_text' from 'ansible.module_utils._text' is deprecated. " \
                     "This feature will be removed from ansible-core version 2.24. " \
                     "Use ansible.module_utils.common.text.converters instead.")
    err.must_include("The `ansible.module_utils.common._collections_compat` module is deprecated. " \
                     "This feature will be removed from ansible-core version 2.24. " \
                     "Use `collections.abc` from the Python standard library instead.")
    err.wont_include("Importing 'to_bytes'")
    err.wont_include("Importing 'to_native'")
    stdout.to_s.must_include("synchronize requires both src and dest parameters are set")
  end

  # Real's linear/free strategy loads every task's action plugin class while
  # iterating, block children included, so a collection action plugin inside
  # a `when:`-guarded block warns exactly like a top-level one - the plugin
  # is loaded before the block's condition is even consulted (issue #1207:
  # juju4.squid's ansible.posix.patch sits in such a block). The warnings are
  # stderr lines and the banners stdout ones, so a single merged capture
  # cannot assert their relative position without racing the two streams;
  # emission before the banner is what the code does, asserted here through
  # the lines being present for a task that never runs.
  it "warns about a block-nested action plugin's imports when the block is skipped" do
    root = PluginSpecHelper.tmp_path("module-utils-import-deprecation-block")
    Dir.mkdir_p(root)
    playbook = File.join(root, "nested.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: a block
            when: false
            block:
              - name: sync inside a skipped block
                ansible.posix.synchronize:
                  src: #{root}/src/
                  dest: #{root}/dest/
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    err = stderr.to_s
    out = stdout.to_s

    status.success?.must_equal(true)
    err.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    action_text = "Importing 'to_text' from 'ansible.module_utils._text' is deprecated. " \
                  "This feature will be removed from ansible-core version 2.24. " \
                  "Use ansible.module_utils.common.text.converters instead."
    compat_text = "The `ansible.module_utils.common._collections_compat` module is deprecated. " \
                  "This feature will be removed from ansible-core version 2.24. " \
                  "Use `collections.abc` from the Python standard library instead."
    err.must_include(action_text)
    err.must_include(compat_text)
    err.scan(action_text).size.must_equal(1)
    out.must_include("TASK [sync inside a skipped block]")
    out.must_include("skipping: [localhost]")
  end
end

private def run_scoped_action_plugin_playbook(playbook : String, collections_root : String) : String
  stderr = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook],
    output: IO::Memory.new, error: stderr,
    env: {"ANSIBLE_COLLECTIONS_PATH" => collections_root})
  status.success?.must_equal(true)
  stderr.to_s
end

# A bare module name resolves its MODULE through every installed
# collection (or through ansible_builtin_runtime.yml's module routing),
# but real's ACTION plugin lookup only searches the collections the task
# scopes - its own `collections:` keyword, else the play's list plus the
# role's meta/main.yml declaration. Bare `k8s:` with none runs through the
# generic `normal` action plugin, so kubernetes.core's action plugin (and
# the deprecated `_text` imports it makes) is never imported and real
# prints nothing (issue #1352, shonpaz123.dockercoins). Scoping the same
# name with `collections: [kubernetes.core]` does load it, live-verified
# against ansible-core 2.21.6 + kubernetes.core 6.1.0.
describe "action plugin import warnings follow the task's collections scope (issue #1352)" do
  it "stays silent for an unscoped bare name whose module resolves through a routing redirect" do
    root = PluginSpecHelper.tmp_path("module-utils-action-scope")
    module_dir = File.join(root, "ansible_collections", "kubernetes", "core", "plugins", "modules")
    action_dir = File.join(root, "ansible_collections", "kubernetes", "core", "plugins", "action")
    Dir.mkdir_p(module_dir)
    Dir.mkdir_p(action_dir)
    File.write(File.join(module_dir, "k8s.py"), "# module\n")
    File.write(File.join(action_dir, "k8s.py"),
      "from ansible.module_utils._text import to_bytes, to_native, to_text\n")

    unscoped = File.join(root, "unscoped.yml")
    File.write(unscoped, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: unscoped bare k8s
            k8s:
              state: present
            when: false
      YAML

    scoped = File.join(root, "scoped.yml")
    File.write(scoped, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        collections:
          - kubernetes.core
        tasks:
          - name: scoped bare k8s
            k8s:
              state: present
            when: false
      YAML

    # The module resolves (it ships in the fixture collection and the
    # builtin runtime routes the bare name to it), but no action plugin is
    # in the task's scope, so nothing may print.
    plain_err = run_scoped_action_plugin_playbook(unscoped, root)
    plain_err.wont_include("Importing 'to_bytes'")
    plain_err.wont_include("Importing 'to_native'")
    plain_err.wont_include("Importing 'to_text'")
    plain_err.wont_include("[DEPRECATION WARNING]")

    scoped_err = run_scoped_action_plugin_playbook(scoped, root)
    scoped_err.must_include("Importing 'to_bytes' from 'ansible.module_utils._text' is deprecated.")
    scoped_err.must_include("Importing 'to_native' from 'ansible.module_utils._text' is deprecated.")
    scoped_err.must_include("Importing 'to_text' from 'ansible.module_utils._text' is deprecated.")
  end
end
