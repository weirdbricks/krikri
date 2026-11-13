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

  it "carries no import deprecations for a module whose installed source migrated off _text (issue #1061)" do
    # ansible.posix 2.2.x moved mount.py's to_bytes/to_native import to
    # ansible.module_utils.common.text.converters, so real prints no
    # deprecation line and registers no entry for the same task
    # (issue #1061) - the installed payload decides, not one modeled
    # release. The fixture shadows any machine-wide ansible.posix through
    # the child's own ANSIBLE_COLLECTIONS_PATH, so this holds on every
    # controller.
    root = PluginSpecHelper.tmp_path("module-utils-migrated-fixture")
    modules = File.join(root, "ansible_collections", "ansible", "posix", "plugins", "modules")
    FileUtils.mkdir_p(modules)
    File.write(File.join(modules, "mount.py"),
      "from ansible.module_utils.common.text.converters import to_bytes, to_native\n")

    result = PluginSpecHelper.run("mount", {} of String => String, env: {"ANSIBLE_COLLECTIONS_PATH" => root})

    result["failed"].as_bool.must_equal(true)
    result["deprecations"]?.must_be_nil
    result["_ansible_core_deprecations"]?.must_be_nil
  end
end

describe "module_utils import deprecations follow the installed payload source" do
  # Fixture-scoped: ANSIBLE_COLLECTIONS_PATH is re-pointed at a scratch
  # ansible.posix tree (ENV is process-wide) and CollectionIndex rescans,
  # so the assertions pin the payload shape instead of inheriting whatever
  # this machine has installed - exclusive! rather than serial! alone for
  # the same reason as collection_index_test.cr: every in-process parse
  # reads that memoized scan.
  exclusive!

  @fixture_root : String = ""
  @saved_collections_path : String?

  before_each do
    @fixture_root = PluginSpecHelper.tmp_path("module-utils-deprecation-fixture")
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "modules"))
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "action"))
    @saved_collections_path = ENV["ANSIBLE_COLLECTIONS_PATH"]?
    ENV["ANSIBLE_COLLECTIONS_PATH"] = @fixture_root
    Krikri::CollectionIndex.reset!
  end

  after_each do
    if saved = @saved_collections_path
      ENV["ANSIBLE_COLLECTIONS_PATH"] = saved
    else
      ENV.delete("ANSIBLE_COLLECTIONS_PATH")
    end
    Krikri::CollectionIndex.reset!
  end

  it "derives the pair from an installed module source that still imports from _text" do
    # ansible.posix 2.1.x's mount.py shape, parenthesized across lines the
    # way real payloads spell it - one deprecation per name, in the
    # payload's own order.
    File.write(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "modules", "mount.py"),
      "from ansible.module_utils._text import (\n    to_bytes,  # payload helper\n    to_native,\n)\n")

    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("ansible.posix.mount").must_equal(["to_bytes", "to_native"])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("mount").must_equal(["to_bytes", "to_native"])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_result_entries("ansible.posix.mount").size.must_equal(2)
  end

  it "derives nothing from an installed module source that migrated off the deprecated path (issue #1061)" do
    # The ansible.posix 2.2.x mount.py shape: same helpers, the new import
    # path, so real warns nothing and neither may this engine.
    File.write(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "modules", "mount.py"),
      "from ansible.module_utils.common.text.converters import to_bytes, to_native\n")

    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("ansible.posix.mount").must_equal([] of String)
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_texts("mount").must_equal([] of String)
  end

  it "derives the action plugin's lines in import order from its installed source" do
    # ansible.posix 2.1.x's synchronize action plugin shape: to_text from
    # the deprecated `_text` path, then the module-level `_collections_compat`
    # deprecation, in that import order.
    File.write(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "modules", "synchronize.py"),
      "from ansible.module_utils._text import to_bytes, to_native\n")
    File.write(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "action", "synchronize.py"),
      "from ansible.module_utils._text import to_text\nfrom ansible.module_utils.common._collections_compat import MutableSequence\n")

    Krikri::ModuleUtilsDeprecations.action_plugin_text_import_deprecation_texts("synchronize").must_equal([
      "Importing 'to_text' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead.",
      Krikri::ModuleUtilsDeprecations::COLLECTIONS_COMPAT_DEPRECATION_TEXT,
    ])
  end

  it "derives nothing for an installed action plugin that migrated off the deprecated paths (issue #1061)" do
    # ansible.posix 2.2.x's synchronize action plugin shape: collections.abc
    # and common.text.converters, so loading it warns nothing.
    File.write(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "modules", "synchronize.py"),
      "from ansible.module_utils.common.text.converters import to_bytes, to_native\n")
    File.write(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "action", "synchronize.py"),
      "from collections.abc import MutableSequence\nfrom ansible.module_utils.common.text.converters import to_text\n")

    Krikri::ModuleUtilsDeprecations.action_plugin_text_import_deprecation_texts("synchronize").must_equal([] of String)
  end

  it "derives an action plugin's deprecated ansible.errors import ahead of its _text one (issue #1198)" do
    # ansible.posix 2.1.x's patch action plugin opens with
    # `from ansible.errors import ... _AnsibleActionDone ...` and then
    # imports to_native from `_text`; ansible-core 2.21's errors
    # __getattr__ deprecates that name too, so real prints both lines when
    # it loads the plugin - even for the when:-skipped patch task a static
    # import leaves behind (live-verified vs 2.21.6). krikri printed only
    # the `_text` line.
    File.write(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "modules", "patch.py"),
      "from ansible.module_utils._text import to_native\n")
    File.write(File.join(@fixture_root, "ansible_collections", "ansible", "posix", "plugins", "action", "patch.py"),
      "from ansible.errors import AnsibleError, AnsibleAction, _AnsibleActionDone, AnsibleActionFail\n" \
      "from ansible.module_utils._text import to_native\n")

    Krikri::ModuleUtilsDeprecations.action_plugin_text_import_deprecation_texts("patch").must_equal([
      "Importing '_AnsibleActionDone' is deprecated. " \
      "This feature will be removed from ansible-core version 2.23. " \
      "Return directly from action plugins instead.",
      "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead.",
    ])
  end

  it "keeps the modeled table for a module payload no installed collection ships" do
    # A krikri-only controller has no payload to read and real cannot run
    # the module at all, so the modeled pair stands (the issue #1000
    # behavior).
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("totally.absent.mount").must_equal(["to_bytes", "to_native"])
  end

  it "keeps the modeled podman_container pair until its own migration boundary (issue #1156)" do
    # The SSH-round shape: the plugin binary runs on the TARGET, where no
    # collection is installed and only the controller-pinned wire version
    # can decide. Real ships the payload from the controller, so its
    # lines depend on the resolved release: containers.podman 1.18.2 and
    # older open podman_container_lib.py with the _text pair, 1.19.0
    # moved it to common.text.converters (source-verified against the
    # tagged releases) - the ansible.posix 2.2.0 boundary alone would
    # model the pair for every 1.x release, forever.
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

  it "follows a module payload's collection-internal module_utils imports (containers.podman's podman_container)" do
    # podman_container.py itself imports nothing deprecated; its
    # module_utils/podman/podman_container_lib.py opens with the
    # to_bytes/to_native pair, and real's shim deprecates when the
    # module's import of THAT file runs (issue #1156's remaining
    # trailer block). The module file's core `ansible.module_utils.basic`
    # import is deliberately not followed - ansible-core's own tree is
    # the clean side.
    base = File.join(@fixture_root, "ansible_collections", "containers", "podman")
    FileUtils.mkdir_p(File.join(base, "plugins", "modules"))
    FileUtils.mkdir_p(File.join(base, "plugins", "module_utils", "podman"))
    File.write(File.join(base, "plugins", "modules", "podman_container.py"),
      "from ansible.module_utils.basic import AnsibleModule  # noqa: F402\n" \
      "from ..module_utils.podman.podman_container_lib import PodmanManager  # noqa: F402\n")
    File.write(File.join(base, "plugins", "module_utils", "podman", "podman_container_lib.py"),
      "from ansible.module_utils._text import to_bytes, to_native  # noqa: F402\n")

    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("containers.podman.podman_container")
      .must_equal(["to_bytes", "to_native"])
  end

  it "follows absolute same-collection module_utils imports in execution order across the chain" do
    # real executes imports depth-first at each statement: the lib's
    # first statement pulls common (whose own _text import fires
    # to_bytes first), then the lib's own import fires to_native.
    # common's import back into the loading lib re-hits the module
    # already executing and adds nothing - the import machinery runs a
    # module once per process.
    base = File.join(@fixture_root, "ansible_collections", "containers", "podman", "plugins")
    FileUtils.mkdir_p(File.join(base, "modules"))
    FileUtils.mkdir_p(File.join(base, "module_utils", "podman"))
    File.write(File.join(base, "modules", "podman_container.py"),
      "from ansible_collections.containers.podman.plugins.module_utils.podman.podman_container_lib import PodmanManager\n")
    File.write(File.join(base, "module_utils", "podman", "podman_container_lib.py"),
      "from ansible_collections.containers.podman.plugins.module_utils.podman.common import LooseVersion\n" \
      "from ansible.module_utils._text import to_native\n")
    File.write(File.join(base, "module_utils", "podman", "common.py"),
      "from ansible_collections.containers.podman.plugins.module_utils.podman.podman_container_lib import lower_keys\n" \
      "from ansible.module_utils._text import to_bytes\n")

    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("containers.podman.podman_container")
      .must_equal(["to_bytes", "to_native"])
  end

  it "follows nothing when the imported chain migrated off the deprecated path" do
    # containers.podman 1.21.x's shape: the same lib, importing from
    # ansible.module_utils.common.text.converters - real warns nothing
    # and neither may this engine, whatever the module file itself
    # spells.
    base = File.join(@fixture_root, "ansible_collections", "containers", "podman", "plugins")
    FileUtils.mkdir_p(File.join(base, "modules"))
    FileUtils.mkdir_p(File.join(base, "module_utils", "podman"))
    File.write(File.join(base, "modules", "podman_container.py"),
      "from ..module_utils.podman.podman_container_lib import PodmanManager\n")
    File.write(File.join(base, "module_utils", "podman", "podman_container_lib.py"),
      "from ansible.module_utils.common.text.converters import to_bytes, to_native\n")

    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("containers.podman.podman_container")
      .must_equal([] of String)
  end

  it "scopes the 2.2.0 migration gate to ansible.posix (issue #1199)" do
    # amazon.aws 10.x's payload still imports to_native even though its
    # release number is far past ansible.posix's 2.2.0 boundary - a
    # blanket version gate silenced every collection whose version is
    # >= 2.2.0 and lost real's lines on the mateothegreat.aws_vpc_delete
    # round.
    base = File.join(@fixture_root, "ansible_collections", "amazon", "aws", "plugins")
    FileUtils.mkdir_p(File.join(base, "modules"))
    FileUtils.mkdir_p(File.join(base, "module_utils"))
    File.write(File.join(base, "modules", "ec2_vpc_net_info.py"),
      "from ..module_utils.modules import AnsibleAWSModule\n")
    File.write(File.join(base, "module_utils", "modules.py"),
      "from ansible.module_utils._text import to_native\n")

    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("amazon.aws.ec2_vpc_net_info", "11.2.0")
      .must_equal(["to_native"])
    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("amazon.aws.ec2_vpc_net_info", "11.3.0")
      .must_equal([] of String)
  end

  it "skips imports real never executes under a TYPE_CHECKING guard (issue #1199)" do
    # botocore.py keeps `from .modules import AnsibleAWSModule` inside
    # `if typing.TYPE_CHECKING:`, which is False at run time - following
    # it reordered (and could add) the payload's real import
    # deprecations.
    base = File.join(@fixture_root, "ansible_collections", "containers", "podman", "plugins")
    FileUtils.mkdir_p(File.join(base, "modules"))
    FileUtils.mkdir_p(File.join(base, "module_utils", "podman"))
    File.write(File.join(base, "modules", "podman_container.py"),
      "from ..module_utils.podman.podman_container_lib import PodmanManager\n")
    File.write(File.join(base, "module_utils", "podman", "podman_container_lib.py"),
      "if typing.TYPE_CHECKING:\n" \
      "    from .common import LooseVersion\n" \
      "\n" \
      "from ansible.module_utils._text import to_native\n")
    File.write(File.join(base, "module_utils", "podman", "common.py"),
      "from ansible.module_utils._text import to_bytes\n")

    Krikri::ModuleUtilsDeprecations.text_import_deprecation_symbols("containers.podman.podman_container")
      .must_equal(["to_native"])
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
