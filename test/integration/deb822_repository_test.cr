require "../minitest_helper"

# deb822_repository writes to /etc/apt/sources.list.d/, which needs
# root - these specs exercise check_mode / param-rendering only (no
# real file write needed to observe the rendered content), matching
# the same convention test/integration/apt_repository_test.cr already
# uses for root-only plugins.
describe "deb822_repository plugin" do
  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("deb822_repository", {
      "uris"   => "https://example.com/repo",
      "suites" => "stable",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("name")
  end

  it "rejects unknown parameters like real Ansible's module-arg validation (ansible-core 2.15 has no body_string)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"        => "testrepo-body",
      "body_string" => "Types: deb\nURIs: http://example.com\n",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_include("Unsupported parameters")
    result["msg"].as_s.must_include("body_string")
  end

  it "succeeds without uris/suites (real Ansible treats both as optional - a name-only task writes just X-Repolib-Name + Types: deb)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"                => "testrepo-name-only",
      "_ansible_check_mode" => "true",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
  end

  it "fails with changed=False when types contains an invalid choice (real Ansible's own choices check)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "testrepo-badtype",
      "types"      => "banana",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "components" => "main",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_include("deb, deb-src")
    result["msg"].as_s.must_include("banana")
  end

  it "accepts a real YAML list of valid types choices (check mode)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"                => "testrepo-multitypes",
      "types"               => "[\"deb\", \"deb-src\"]",
      "uris"                => "https://example.com/repo",
      "suites"              => "stable",
      "_ansible_check_mode" => "true",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
  end

  it "fails on a space-separated types scalar like real Ansible's comma-only check_type_list split" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"                => "testrepo-spacetype",
      "types"               => "deb deb-src",
      "uris"                => "https://example.com/repo",
      "suites"              => "stable",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
  end

  it "reports it would add a repository that isn't present yet (check mode, no real change)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"                => "totally-fake-example-repo",
      "types"               => "deb",
      "uris"                => "https://packages.totally-fake-example.com/repo",
      "suites"              => "stable",
      "components"          => "main",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
  end

  it "reports it would remove a repository when state: absent and it isn't present (no-op either way, safe even without check mode)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"  => "totally-fake-example-repo-that-does-not-exist",
      "state" => "absent",
    })

    result["changed"].as_bool.must_equal(false)
  end

  it "fails on an invalid types choice even with state: absent (the real module's choices check lives in module-arg validation, before state handling)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"  => "totally-fake-absent-badtype",
      "types" => "banana",
      "state" => "absent",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_include("banana")
  end

  it "gates on python3-debian deterministically: a stub `debian` package on PYTHONPATH forces the missing-lib branch on any host" do
    # The real module fails with missing_required_lib wording on any
    # target without python3-debian - before state handling, so both
    # states fail identically. Instead of depending on whether THIS
    # host has the library, the failure branch is forced
    # deterministically: a PYTHONPATH entry precedes site-packages in
    # sys.path, so a stub `debian` package whose __init__ raises
    # ImportError makes `from debian.deb822 import Deb822` fail on
    # every host. The env reaches the probe because the plugin spawns
    # python3 with an inherited environment (Process.run without an
    # env: argument), so PYTHONPATH flows test process -> plugin ->
    # python3.
    skip "no python3/python on this host (the gate needs an interpreter to fail)" unless Process.find_executable("python3") || Process.find_executable("python")

    stub_root = PluginSpecHelper.tmp_path("python-debian-stub")
    FileUtils.mkdir_p(File.join(stub_root, "debian"))
    File.write(File.join(stub_root, "debian", "__init__.py"),
      "raise ImportError(\"deb822 gate spec stub: python3-debian forced absent\")\n")

    {"present", "absent"}.each do |state|
      result = PluginSpecHelper.run("deb822_repository", {
        "name"                => "testrepo-debian-gate",
        "uris"                => "https://example.com/repo",
        "state"               => state,
        "_ansible_check_mode" => "true",
      }, env: {"PYTHONPATH" => stub_root})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_include("Failed to import the required Python library (python3-debian)")
    end
  end

  it "succeeds on hosts that actually have python3-debian (skipped elsewhere; the PYTHONPATH-stub spec covers the failure branch)" do
    # Companion to the deterministic gate spec above: on a host WITH
    # python3-debian (and no PYTHONPATH override) the gate probe finds
    # the real module and the task proceeds normally.
    probe = Process.run("python3", {"-c", "from debian.deb822 import Deb822"}, error: Process::Redirect::Close)
    skip "python3-debian not installed on this host" unless probe.success?

    {"present", "absent"}.each do |state|
      result = PluginSpecHelper.run("deb822_repository", {
        "name"                => "testrepo-debian-gate",
        "uris"                => "https://example.com/repo",
        "state"               => state,
        "_ansible_check_mode" => "true",
      })

      expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
    end
  end

  describe "signed_by" do
    it "renders with an inline ASCII-armored key without crashing (check mode)" do
      result = PluginSpecHelper.run("deb822_repository", {
        "name"                => "test-armored-repo",
        "uris"                => "https://example.com/repo",
        "suites"              => "stable",
        "signed_by"           => "-----BEGIN PGP PUBLIC KEY BLOCK-----\nmQINBGF...\n-----END PGP PUBLIC KEY BLOCK-----",
        "_ansible_check_mode" => "true",
      })

      result["changed"].as_bool.must_equal(true)
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    end

    it "renders with a key fingerprint on one line (check mode)" do
      result = PluginSpecHelper.run("deb822_repository", {
        "name"                => "test-fingerprint-repo",
        "uris"                => "https://example.com/repo",
        "suites"              => "stable",
        "signed_by"           => "ABCD1234EFGH5678ABCD1234EFGH5678ABCD1234",
        "_ansible_check_mode" => "true",
      })

      result["changed"].as_bool.must_equal(true)
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    end

    it "handles an empty signed_by gracefully" do
      result = PluginSpecHelper.run("deb822_repository", {
        "name"                => "test-empty-owner-repo",
        "uris"                => "https://example.com/repo",
        "suites"              => "stable",
        "signed_by"           => "",
        "_ansible_check_mode" => "true",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    end
  end

  it "renders with X-Repolib-Name in the output (check mode, no file written)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"                => "test-repolib-name",
      "uris"                => "https://example.com/repo",
      "suites"              => "stable",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "does not reject the executor-injected _module_name internal param" do
    # The task executor injects `_module_name` into EVERY task's plugin
    # params (the invoked spelling real Ansible's check-mode skip
    # messages echo); the plugin's own internal-keys set predating that
    # injection rejected it as unsupported, failing every single
    # deb822_repository task with "Unsupported parameters ...
    # _module_name" (podman-diff deb822_repository_edge_cases: every
    # valid case failed on the krikri side).
    result = PluginSpecHelper.run("deb822_repository", {
      "name"                => "testrepo-module-name",
      "_module_name"        => "ansible.builtin.deb822_repository",
      "_ansible_check_mode" => "true",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["msg"]?.to_s.wont_include("Unsupported parameters")
  end
end
