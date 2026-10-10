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
# afterwards.
describe Krikri::CollectionIndex do
  # ------------------------------------------------------------------
  # Fixture-scoped specs: an isolated collection tree via
  # ANSIBLE_COLLECTIONS_PATH, so the assertions don't depend on what
  # else this machine has installed.
  serial!

  @fixture_root : String = ""

  before_each do
    @fixture_root = PluginSpecHelper.tmp_path("collection-index-fixture")
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "testns", "prov", "plugins", "modules"))
    File.write(File.join(@fixture_root, "ansible_collections", "testns", "prov", "plugins", "modules", "thing.py"), "# fixture module\n")
    # A collection whose runtime.yml redirects another leaf onto prov's
    # module - the redirect must count as "provides".
    FileUtils.mkdir_p(File.join(@fixture_root, "ansible_collections", "testns", "chain", "meta"))
    File.write(File.join(@fixture_root, "ansible_collections", "testns", "chain", "meta", "runtime.yml"),
      <<-YAML
        plugin_routing:
          modules:
            other:
              redirect: testns.prov.thing
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

  it "refuses an FQCN whose installed fixture collection lacks the module file (no warning)" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.prov.missing")
    result[:resolves].must_equal(false)
    result[:missing_collection_warning].must_be_nil
  end

  it "follows the collection's own meta/runtime.yml redirect to a module file that exists" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.chain.other")
    result[:resolves].must_equal(true)
  end

  it "refuses an FQCN whose namespace is absent, with the namespace-level import warning" do
    result = Krikri::CollectionIndex.controller_resolves?("absentns.absentcoll.thing")
    result[:resolves].must_equal(false)
    result[:missing_collection_warning].must_equal(
      "Error loading plugin 'absentns.absentcoll.thing': No module named 'ansible_collections.absentns'")
  end

  it "refuses an FQCN whose collection is absent inside a present namespace, with the collection-level warning" do
    result = Krikri::CollectionIndex.controller_resolves?("testns.absentcoll.thing")
    result[:resolves].must_equal(false)
    result[:missing_collection_warning].must_equal(
      "Error loading plugin 'testns.absentcoll.thing': No module named 'ansible_collections.testns.absentcoll'")
  end

  it "resolves a bare name through the collections: keyword entries" do
    result = Krikri::CollectionIndex.controller_resolves?("thing", ["testns.prov"])
    result[:resolves].must_equal(true)
  end

  it "refuses a bare name the keyword collections cannot provide either" do
    result = Krikri::CollectionIndex.controller_resolves?("nosuchthing", ["testns.prov"])
    result[:resolves].must_equal(false)
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

  it "refuses a bare name whose builtin redirect dies on an absent collection (gc_storage), warning naming the target" do
    # The fixture carries a community.* collection (community.crypto)
    # but no community.google, so the redirect chain for bare
    # `gc_storage:` dies on an absent collection INSIDE a present
    # namespace - the collection-level import warning, deterministic on
    # any controller.
    result = Krikri::CollectionIndex.controller_resolves?("gc_storage")
    result[:resolves].must_equal(false)
    result[:missing_collection_warning].must_equal(
      "Error loading plugin 'community.google.gc_storage': No module named 'ansible_collections.community.google'")
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
    result[:missing_collection_warning].must_be_nil
  end

  it "refuses a missing-collection FQCN the way ansible-core does (freeipa.ansible_freeipa)" do
    result = Krikri::CollectionIndex.controller_resolves?("freeipa.ansible_freeipa.ipaclient_setup_nis")
    result[:resolves].must_equal(false)
    result[:missing_collection_warning].must_equal(
      "Error loading plugin 'freeipa.ansible_freeipa.ipaclient_setup_nis': No module named 'ansible_collections.freeipa'")
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
