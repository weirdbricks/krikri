require "../minitest_helper"
require "file_utils"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/collection_index"

# The controller collection-set awareness index: real's module-name
# resolution rules applied against the collections actually installed on
# the controller this engine runs on (ansible-core 2.19.11's own
# behavior, live-verified: a name real cannot resolve to an existing
# module file refuses the whole playbook at load).
#
# Most specs here read the REAL machine's collection state (the
# dist-packages ansible-core install plus ~/.ansible/collections), the
# same state the pinned kubernetes.core/amazon.aws specs in
# playbook_parser_test.cr already depend on. The fixture-scoped specs
# point ANSIBLE_COLLECTIONS_PATH at a scratch tree instead and are
# serial! (ENV is process-wide); CollectionIndex.reset! forgets the
# scan so the fixture is actually seen, and the env is restored
# afterwards. exclusive! rather than serial! alone: the scan's
# memoized roots are read by every in-process parse in this process,
# not just by tests that opt in to serial!, so no other test may run
# inside the fixture window.
describe Krikri::CollectionIndex do
  # ------------------------------------------------------------------
  # Fixture-scoped specs: an isolated collection tree via
  # ANSIBLE_COLLECTIONS_PATH, so the assertions don't depend on what
  # else this machine has installed.
  exclusive!

  @fixture_root : String = ""

  before_each do
    @fixture_root = PluginSpecHelper.tmp_path("collection-index-fixture")
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "testns", "prov", "plugins", "modules"))
    File.write(File.join(@fixture_root, "ansible_collections", "testns", "prov", "plugins", "modules", "thing.py"), "# fixture module\n")
    # A bare lookup name's installed-collection scan (lookup and filter
    # names search EVERY installed collection, unlike modules/actions)
    # must find this file.
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "testns", "prov", "plugins", "lookup"))
    File.write(File.join(@fixture_root, "ansible_collections", "testns", "prov", "plugins", "lookup", "thing_lookup.py"), "# fixture lookup\n")
    # A collection whose runtime.yml redirects another leaf onto prov's
    # module - the redirect must count as "provides".
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "testns", "chain", "meta"))
    File.write(File.join(@fixture_root, "ansible_collections", "testns", "chain", "meta", "runtime.yml"),
      <<-YAML
        plugin_routing:
          modules:
            other:
              redirect: testns.prov.thing
          lookup:
            other_lookup:
              redirect: testns.prov.thing_lookup
        YAML
    )
    # Real collection/module shapes the redirect-following specs below
    # pin against: community.crypto's x509_certificate (the target of
    # the bare `openssl_certificate` builtin-runtime redirect) and
    # amazon.aws's autoscaling_group_info (a REAL module leaf krikri has
    # NOT ported). Stubbing them in the fixture makes those specs
    # deterministic on any controller - the dev machine's own installed
    # collections sit behind the fixture in the search order and agree
    # with it, while a bare CI container has nothing else to consult.
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "community", "crypto", "plugins", "modules"))
    File.write(File.join(@fixture_root, "ansible_collections", "community", "crypto", "plugins", "modules", "x509_certificate.py"), "# fixture module\n")
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "amazon", "aws", "plugins", "modules"))
    File.write(File.join(@fixture_root, "ansible_collections", "amazon", "aws", "plugins", "modules", "autoscaling_group_info.py"), "# fixture module\n")
    ENV["ANSIBLE_COLLECTIONS_PATH"] = @fixture_root
    Krikri::CollectionIndex.reset!
  end

  after_each do
    ENV.delete("ANSIBLE_COLLECTIONS_PATH")
    Krikri::CollectionIndex.reset!
  end

  it "resolves an FQCN whose fixture collection ships the module file" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.prov.thing")
    result[:resolves].must_equal(true)
  end

  it "refuses an FQCN whose installed fixture collection lacks the module file" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.prov.missing")
    result[:resolves].must_equal(false)
  end

  # issue #1253: an FQCR may carry plugin-type SUBDIR segments
  # (`ns.coll.subdir.resource`). ansible-core imports the subdir as a
  # package under plugins/modules/ and looks the resource up beside it; a
  # subdir naming a module FILE is imported with that file's directory as
  # the search root, so `testns.prov.thing.thing` resolves to thing.py and
  # real RUNS it (live-verified against ansible-core 2.21.6 with
  # community.general.locale_gen.locale_gen).
  it "resolves an FQCR whose subdir segment and resource both name module files" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.prov.thing.thing")
    result[:resolves].must_equal(true)
    Krikri::CollectionIndex.fqcr_subdir_resolves?("testns.prov.thing.thing").must_equal(true)
  end

  it "refuses an FQCR whose subdir segment names nothing in the collection" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.prov.nosuchsubdir.thing")
    result[:resolves].must_equal(false)
    Krikri::CollectionIndex.fqcr_subdir_resolves?("testns.prov.nosuchsubdir.thing").must_equal(false)
  end

  it "refuses an FQCR whose subdir segment resolves but whose resource file is missing" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.prov.thing.nosuchresource")
    result[:resolves].must_equal(false)
  end

  # The release-version lookups the deprecation model's 2.1.x-vs-2.2.x
  # gate rides on (issue #1060): the resolved module's collection
  # release, read from the copy real's loader would import from, for
  # both the FQCN spelling and a bare name matched by leaf.
  it "reports the resolved module's collection release version" do
    File.write(File.join(@fixture_root, "ansible_collections", "testns", "prov", "MANIFEST.json"),
      %({"collection_info": {"namespace": "testns", "name": "prov", "version": "2.2.2"}}))

    Krikri::CollectionIndex.module_provider_version("testns.prov.thing").must_equal("2.2.2")
    Krikri::CollectionIndex.module_provider_version("thing").must_equal("2.2.2")
    # The chain's end is the release that matters: testns.chain redirects
    # `other` onto prov's module, whose own manifest pins 2.2.2.
    Krikri::CollectionIndex.module_provider_version("testns.chain.other").must_equal("2.2.2")
    # A name only ansible-core provides, or one no collection ships,
    # pins no collection release at all.
    Krikri::CollectionIndex.module_provider_version("ansible.builtin.copy").must_be_nil
    Krikri::CollectionIndex.module_provider_version("no_such_module_xyzzy").must_be_nil
  end

  # The comparison the release gate uses: numeric leading segments, and
  # an unknown/unparseable release counting as OLDER (the plugins keep
  # modeling the 2.1.x module line whenever the executor cannot pin one).
  it "compares release versions with an unknown release counting as older" do
    Krikri::CollectionIndex.version_before?("2.1.0", 2, 2, 0).must_equal(true)
    Krikri::CollectionIndex.version_before?("2.1.9", 2, 2, 0).must_equal(true)
    Krikri::CollectionIndex.version_before?("2.2.0", 2, 2, 0).must_equal(false)
    Krikri::CollectionIndex.version_before?("2.2.2", 2, 2, 0).must_equal(false)
    Krikri::CollectionIndex.version_before?("12.5.0", 2, 2, 0).must_equal(false)
    Krikri::CollectionIndex.version_before?(nil, 2, 2, 0).must_equal(true)
  end

  it "follows the collection's own meta/runtime.yml redirect to a module file that exists" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.chain.other")
    result[:resolves].must_equal(true)
  end

  it "refuses an FQCN whose namespace is absent" do
    # ansible-core 2.21's loader swallows the collection ImportError (its
    # 2.19-era "Error loading plugin" [WARNING] is gone - issue #965),
    # so the refusal stands alone.
    result = Krikri::CollectionIndex.controller_resolves?("absentns.absentcoll.thing")
    result[:resolves].must_equal(false)
  end

  it "refuses an FQCN whose collection is absent inside a present namespace" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.absentcoll.thing")
    result[:resolves].must_equal(false)
  end

  it "resolves a bare name through the collections: keyword entries" do
    result = Krikri::CollectionIndex.controller_resolves?("thing", ["testns.prov"])
    result[:resolves].must_equal(true)
  end

  it "refuses a bare name the keyword collections cannot provide either" do
    result = Krikri::CollectionIndex.controller_resolves?("nosuchthing", ["testns.prov"])
    result[:resolves].must_equal(false)
  end

  it "resolves a bare lookup name an installed collection's plugins/lookup ships (issue #751)" do
    # Bare lookup names (unlike bare module names) are scanned across
    # EVERY installed collection - real runs community.general's own
    # `dig` with no `collections:` keyword anywhere (live-verified vs
    # 2.19.11) - so the fixture's plugin file must count as provided.
    Krikri::CollectionIndex.bare_lookup_resolves?("thing_lookup").must_equal(true)
  end

  it "follows a collection's lookup-kind runtime redirect for a bare lookup name" do
    # The builtin runtime is not the only redirect source: a
    # collection's own meta/runtime.yml plugin_routing.lookup table
    # participates the same way it does for modules.
    Krikri::CollectionIndex.bare_lookup_resolves?("other_lookup").must_equal(true)
  end

  it "refuses a bare lookup name neither ansible-core nor any collection provides" do
    # The definite negative is what the lookup dispatch's not-found
    # gate (issue #751) refuses on: ansible-core's own plugins/lookup
    # tree, its builtin-runtime lookup redirects and every installed
    # collection's plugins/lookup all miss. ansible-core must be
    # discoverable here (same assumption the bare module refusal above
    # makes) - without it the answer is the permissive nil.
    Krikri::CollectionIndex.bare_lookup_resolves?("nope_nope_bare_missing").must_equal(false)
  end

  it "resolves an installed collection's real module even when krikri has not implemented it" do
    # The fixture's amazon.aws ships autoscaling_group_info; the name
    # resolves for real, so the engine must NOT refuse it (the lazy
    # unavailable_module flow keeps ownership).
    result = Krikri::CollectionIndex.controller_resolves?("amazon.aws.autoscaling_group_info")
    result[:resolves].must_equal(true)
  end

  it "follows a builtin-runtime redirect to an installed collection's module (openssl_certificate)" do
    result = Krikri::CollectionIndex.controller_resolves?("openssl_certificate")
    result[:resolves].must_equal(true)
  end

  it "refuses a bare name whose builtin redirect dies on an absent collection (gc_storage)" do
    # The fixture carries a community.* collection (community.crypto)
    # but no community.google, so the redirect chain for bare
    # `gc_storage:` dies on an absent collection INSIDE a present
    # namespace - a silent refusal under ansible-core 2.21 (issue #965).
    result = Krikri::CollectionIndex.controller_resolves?("gc_storage")
    result[:resolves].must_equal(false)
  end

  it "treats an installed ansible.netcommon as the truth for its own names" do
    # Real ansible refuses an FQCN whose installed collection ships no
    # such module (ansible.netcommon has no cli_parse, ansible-playbook
    # dies at load), so the installed collection must win over the
    # blanket legacy-core rule for ansible.netcommon.*.
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "ansible", "netcommon", "plugins", "modules"))
    File.write(File.join(@fixture_root, "ansible_collections", "ansible", "netcommon", "plugins", "modules", "cli_backup.py"), "# fixture module\n")
    ENV["ANSIBLE_COLLECTIONS_PATH"] = @fixture_root
    Krikri::CollectionIndex.reset!
    result = Krikri::CollectionIndex.controller_resolves?("ansible.netcommon.cli_backup")
    result[:resolves].must_equal(true)
    result = Krikri::CollectionIndex.controller_resolves?("ansible.netcommon.cli_parse")
    result[:resolves].must_equal(false)
  end

  # ------------------------------------------------------------------
  # Real-machine-state specs: the fixture env is gone again, the index
  # rescanned the controller's actual collections.
  it "reports ansible-core builtin modules as resolvable bare names" do
    result = Krikri::CollectionIndex.controller_resolves?("getent")
    result[:resolves].must_equal(true)
  end

  it "refuses a bare name that is neither builtin nor redirected (docker, as ansible-core does)" do
    result = Krikri::CollectionIndex.controller_resolves?("docker")
    result[:resolves].must_equal(false)
  end

  it "refuses a missing-collection FQCN the way ansible-core does (freeipa.ansible_freeipa)" do
    result = Krikri::CollectionIndex.controller_resolves?("freeipa.ansible_freeipa.ipaclient_setup_nis")
    result[:resolves].must_equal(false)
  end

  it "leaves ansible.builtin. spellings to the engine's own resolution (never refuses)" do
    result = Krikri::CollectionIndex.controller_resolves?("ansible.builtin.sysvinit")
    result[:resolves].must_be_nil
  end

  it "stays unsure for templated names" do
    result = Krikri::CollectionIndex.controller_resolves?("{{ pkg_mgr }}")
    result[:resolves].must_be_nil
  end

  it "finds a role-private library/ module source and refuses nothing" do
    root = PluginSpecHelper.tmp_path("collection-index-library")
    FileUtils.mkdir_p(File.join(root, "roles", "librole", "library"))
    File.write(File.join(root, "roles", "librole", "library", "getthing.py"), "# fixture\n")
    result = Krikri::CollectionIndex.controller_resolves?("getthing",
      role_path: File.join(root, "roles", "librole"))
    result[:resolves].must_equal(true)
  end

  it "finds a role-local action_plugins file as a bare-name source" do
    root = PluginSpecHelper.tmp_path("collection-index-action-plugins")
    FileUtils.mkdir_p(File.join(root, "roles", "actrole", "action_plugins"))
    File.write(File.join(root, "roles", "actrole", "action_plugins", "warn.py"), "# fixture\n")
    result = Krikri::CollectionIndex.controller_resolves?("warn",
      role_path: File.join(root, "roles", "actrole"))
    result[:resolves].must_equal(true)
  end

  it "refuses a bare name whose role-local action_plugins file is absent" do
    root = PluginSpecHelper.tmp_path("collection-index-action-plugins-empty")
    FileUtils.mkdir_p(File.join(root, "roles", "noactrole", "action_plugins"))
    result = Krikri::CollectionIndex.controller_resolves?("nosuchaction",
      role_path: File.join(root, "roles", "noactrole"))
    result[:resolves].must_equal(false)
  end

  it "does not count a dangling library/ symlink as a module source" do
    root = PluginSpecHelper.tmp_path("collection-index-dangling")
    FileUtils.mkdir_p(File.join(root, "roles", "dangrole", "library"))
    File.symlink("../submodules/missing/getthing2.py",
      File.join(root, "roles", "dangrole", "library", "getthing2.py"))
    result = Krikri::CollectionIndex.controller_resolves?("getthing2",
      role_path: File.join(root, "roles", "dangrole"))
    result[:resolves].must_equal(false)
  end

  it "resolves a bare action name via a role-local action_plugins/<name>.py file" do
    root = PluginSpecHelper.tmp_path("collection-index-action-plugin")
    FileUtils.mkdir_p(File.join(root, "roles", "aprole", "action_plugins"))
    File.write(File.join(root, "roles", "aprole", "action_plugins", "warnx.py"), "# fixture\n")
    result = Krikri::CollectionIndex.controller_resolves?("warnx",
      role_path: File.join(root, "roles", "aprole"))
    result[:resolves].must_equal(true)
  end

  it "still refuses a bare action name with no role-local action_plugins file" do
    root = PluginSpecHelper.tmp_path("collection-index-no-action-plugin")
    FileUtils.mkdir_p(File.join(root, "roles", "bare-role", "tasks"))
    result = Krikri::CollectionIndex.controller_resolves?("warnx",
      role_path: File.join(root, "roles", "bare-role"))
    result[:resolves].must_equal(false)
  end

  # ------------------------------------------------------------------
  # The no-ansible-core fallback (round 5440000's confirm roles: the
  # krikri host has no ansible-core install at all - the index used to
  # degrade every builtin-dependent answer to nil ("unsure") and every
  # refusal became a run). With the baked 2.19.11 name set + redirect
  # tables the resolution is definitive even there.
  it "bare redirect into an absent collection refuses with no ansible-core on the machine" do
    # Simulate "no ansible-core anywhere": clear the discovered package
    # dirs through reset! + an env where the standard paths are empty.
    # ANSIBLE_COLLECTIONS_PATH points at an EMPTY tree (no collections),
    # and the baked builtin tables carry the name resolution.
    empty_root = PluginSpecHelper.tmp_path("collection-index-empty")
    FileUtils.mkdir_p(File.join(empty_root, "ansible_collections"))
    ENV["ANSIBLE_COLLECTIONS_PATH"] = empty_root
    Krikri::CollectionIndex.reset!

    # `vsphere_guest` is not a builtin module file; its builtin-runtime
    # redirect lands in community.vmware, which this fixture does not
    # have - real refuses the playbook at load on such a controller.
    resolution = Krikri::CollectionIndex.controller_resolves?("vsphere_guest")
    resolution[:resolves].must_equal(false)
  end

  it "bare builtin name resolves with no ansible-core on the machine" do
    empty_root = PluginSpecHelper.tmp_path("collection-index-empty-2")
    FileUtils.mkdir_p(File.join(empty_root, "ansible_collections"))
    ENV["ANSIBLE_COLLECTIONS_PATH"] = empty_root
    Krikri::CollectionIndex.reset!

    resolution = Krikri::CollectionIndex.controller_resolves?("command")
    resolution[:resolves].must_equal(true)
  end
end
