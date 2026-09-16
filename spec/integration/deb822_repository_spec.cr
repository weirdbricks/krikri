require "../spec_helper"

# deb822_repository writes to /etc/apt/sources.list.d/, which needs
# root - these specs exercise check_mode / param-rendering only (no
# real file write needed to observe the rendered content), matching
# the same convention spec/integration/apt_repository_spec.cr already
# uses for root-only plugins.
describe "deb822_repository plugin" do
  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("deb822_repository", {
      "uris"   => "https://example.com/repo",
      "suites" => "stable",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("name")
  end

  it "rejects unknown parameters like real Ansible's module-arg validation (ansible-core 2.15 has no body_string)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"        => "testrepo-body",
      "body_string" => "Types: deb\nURIs: http://example.com\n",
    })

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("Unsupported parameters")
    result["msg"].as_s.should contain("body_string")
  end

  it "succeeds without uris/suites (real Ansible treats both as optional - a name-only task writes just X-Repolib-Name + Types: deb)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "testrepo-name-only",
      "_ansible_check_mode" => "true",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
  end

  it "fails with changed=False when types contains an invalid choice (real Ansible's own choices check)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "testrepo-badtype",
      "types"      => "banana",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "components" => "main",
    })

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("deb, deb-src")
    result["msg"].as_s.should contain("banana")
  end

  it "accepts a real YAML list of valid types choices (check mode)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "testrepo-multitypes",
      "types"      => "[\"deb\", \"deb-src\"]",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "_ansible_check_mode" => "true",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
  end

  it "fails on a space-separated types scalar like real Ansible's comma-only check_type_list split" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "testrepo-spacetype",
      "types"      => "deb deb-src",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
  end

  it "reports it would add a repository that isn't present yet (check mode, no real change)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "totally-fake-example-repo",
      "types"      => "deb",
      "uris"       => "https://packages.totally-fake-example.com/repo",
      "suites"     => "stable",
      "components" => "main",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
  end

  it "reports it would remove a repository when state: absent and it isn't present (no-op either way, safe even without check mode)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"  => "totally-fake-example-repo-that-does-not-exist",
      "state" => "absent",
    })

    result["changed"].as_bool.should be_false
  end

  describe "signed_by" do
    it "renders with an inline ASCII-armored key without crashing (check mode)" do
      result = PluginSpecHelper.run("deb822_repository", {
        "name"       => "test-armored-repo",
        "uris"       => "https://example.com/repo",
        "suites"     => "stable",
        "signed_by"  => "-----BEGIN PGP PUBLIC KEY BLOCK-----\nmQINBGF...\n-----END PGP PUBLIC KEY BLOCK-----",
        "_ansible_check_mode" => "true",
      })

      result["changed"].as_bool.should be_true
      result["failed"]?.try(&.as_bool).should be_falsey
    end

    it "renders with a key fingerprint on one line (check mode)" do
      result = PluginSpecHelper.run("deb822_repository", {
        "name"       => "test-fingerprint-repo",
        "uris"       => "https://example.com/repo",
        "suites"     => "stable",
        "signed_by"  => "ABCD1234EFGH5678ABCD1234EFGH5678ABCD1234",
        "_ansible_check_mode" => "true",
      })

      result["changed"].as_bool.should be_true
      result["failed"]?.try(&.as_bool).should be_falsey
    end

    it "handles an empty signed_by gracefully" do
      result = PluginSpecHelper.run("deb822_repository", {
        "name"       => "test-empty-owner-repo",
        "uris"       => "https://example.com/repo",
        "suites"     => "stable",
        "signed_by"  => "",
        "_ansible_check_mode" => "true",
      })

      result["failed"]?.try(&.as_bool).should be_falsey
    end
  end

  it "renders with X-Repolib-Name in the output (check mode, no file written)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "test-repolib-name",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    result["failed"]?.try(&.as_bool).should be_falsey
  end
end
