require "../minitest_helper"
require "file_utils"
require "http/server"

# apt_repository writes to /etc/apt/sources.list.d/, which needs root -
# the earlier specs exercise check_mode only (read-only, safe on a real
# machine); the sources_added/sources_removed ones write for real but
# through the plugin's `_sources_list`/`_sources_list_d` scratch-dir
# seams (same convention as test/integration/apt_repository_param_coverage_test.cr),
# so nothing here touches /etc/apt either.
private def scratch_sources(tag : String) : {String, String}
  dir = File.join(Dir.tempdir, "krikri-aptrepo-fields-#{tag}-#{Random.rand(1_000_000)}")
  list_d = File.join(dir, "sources.list.d")
  Dir.mkdir_p(list_d)
  {File.join(dir, "sources.list"), list_d}
end

# A tiny local stand-in for the Launchpad API (Crystal stdlib HTTP::Server,
# no internet access): answers the metadata shape a live PPA returns
# (200 + signing_key_fingerprint) for one known archive and 404 for
# anything else - a deleted PPA's real answer. The specs point the
# plugin's `_ppa_api_base` seam here so the metadata fetch (and its
# failure shapes) is exercised for real without network access.
private APT_REPO_LP_FINGERPRINT = "0123456789ABCDEF0123456789ABCDEF01234567"

private APT_REPO_LP_TEST_SERVER = HTTP::Server.new do |context|
  case context.request.path
  when "/~nginx/+archive/stable"
    context.response.status_code = 200
    context.response.headers["Content-Type"] = "application/json"
    context.response.print(%({"signing_key_fingerprint": "#{APT_REPO_LP_FINGERPRINT}"}))
  else
    context.response.status_code = 404
  end
end
private APT_REPO_LP_TEST_ADDRESS = APT_REPO_LP_TEST_SERVER.bind_unused_port
spawn { APT_REPO_LP_TEST_SERVER.listen }
Fiber.yield

private APT_REPO_LP_TEST_BASE = "http://#{APT_REPO_LP_TEST_ADDRESS}"

describe "apt_repository plugin" do
  it "reports it would add a repository that isn't present yet (check mode, no real change)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"                => "deb https://packages.totally-fake-example.com/repo stable main",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["state"].as_s.must_equal("present")
  end

  it "normalizes whitespace before checking/reporting the repo line" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"                => "  deb   https://packages.totally-fake-example.com/repo   stable main  ",
      "_ansible_check_mode" => "true",
    })

    result["repo"].as_s.must_equal("deb https://packages.totally-fake-example.com/repo stable main")
  end

  it "reports it would remove a repository when state: absent and it isn't present (no-op either way, safe even without check mode)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"  => "deb https://packages.totally-fake-example.com/repo stable main",
      "state" => "absent",
    })

    result["changed"].as_bool.must_equal(false)
    result["state"].as_s.must_equal("absent")
  end

  it "fails with a clear message when repo is missing" do
    result = PluginSpecHelper.run("apt_repository", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("repo")
  end

  it "fails with a clear message for a line that isn't deb/deb-src or ppa:" do
    result = PluginSpecHelper.run("apt_repository", {"repo" => "not a valid repo line"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Invalid repository string")
  end

  # ppa: shorthand (see plugins/apt_repository.cr's own class doc for the
  # full formula breakdown - expands to a real deb line, fetches the PPA
  # metadata from the Launchpad API over HTTP, and exports its signing
  # key via gpg). Real Ansible's add_source calls _get_ppa_info - the
  # metadata fetch - the moment the expanded line is not already one of
  # the enabled sources, check mode included (only the key import is
  # `if not self.module.check_mode`), and returns before it only for a
  # line already present or state: absent. The specs below point the
  # `_ppa_api_base` seam at the local stand-in server above so that fetch
  # is exercised for real without internet access or /etc/apt writes; the
  # actual network+GPG import path was verified by hand in a container
  # instead - see git log.
  it "expands ppa: to the exact real-Ansible deb line shape and reports it would add (check mode)" do
    sources_list, list_d = scratch_sources("ppa-check")

    result = PluginSpecHelper.run("apt_repository", {
      "repo" => "ppa:nginx/stable", "codename" => "jammy", "_ansible_check_mode" => "true",
      "_ppa_api_base" => APT_REPO_LP_TEST_BASE,
      "_sources_list" => sources_list, "_sources_list_d" => list_d,
    })

    result["changed"].as_bool.must_equal(true)
    result["repo"].as_s.must_equal("deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main")
  end

  # Issue #1051 (marauderxtreme.local_system's "Activate all neat PPAs"):
  # ppa:dawidd0811/neofetch was deleted upstream, and a check-mode run
  # must fail on it exactly like a real one - Ansible fails the task with
  # "failed to fetch PPA information, error was: HTTP Error 404: Not
  # Found" even under --check (its metadata fetch is not check_mode-gated)
  # and the failed task stops the play, where this engine reported
  # changed and ran the whole tail of the play on its own.
  it "fails a check-mode ppa: add when the Launchpad API answers 404 (issue #1051)" do
    sources_list, list_d = scratch_sources("ppa-404-check")

    result = PluginSpecHelper.run("apt_repository", {
      "repo" => "ppa:dawidd0811/neofetch", "codename" => "jammy", "_ansible_check_mode" => "true",
      "_ppa_api_base" => APT_REPO_LP_TEST_BASE,
      "_sources_list" => sources_list, "_sources_list_d" => list_d,
    })

    result["changed"].as_bool.must_equal(false)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("failed to fetch PPA information, error was: HTTP Error 404: Not Found")
  end

  it "fails a real ppa: add when the Launchpad API answers 404 before writing anything" do
    sources_list, list_d = scratch_sources("ppa-404-real")

    result = PluginSpecHelper.run("apt_repository", {
      "repo" => "ppa:dawidd0811/neofetch", "codename" => "jammy",
      "_ppa_api_base" => APT_REPO_LP_TEST_BASE,
      "_sources_list" => sources_list, "_sources_list_d" => list_d,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("failed to fetch PPA information, error was: HTTP Error 404: Not Found")
    File.exists?(sources_list).must_equal(false)
    Dir.glob(File.join(list_d, "*")).must_be_empty
  end

  it "answers ok for a check-mode ppa: whose line is already present without touching the API" do
    sources_list, list_d = scratch_sources("ppa-present")
    File.write(sources_list, "deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main\n")

    result = PluginSpecHelper.run("apt_repository", {
      "repo" => "ppa:nginx/stable", "codename" => "jammy", "_ansible_check_mode" => "true",
      "_ppa_api_base" => "http://127.0.0.1:1",
      "_sources_list" => sources_list, "_sources_list_d" => list_d,
    })

    result["changed"].as_bool.must_equal(false)
    result["state"].as_s.must_equal("present")
    result["repo"].as_s.must_equal("deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main")
  end

  it "reports a ppa: repository already absent as a no-op (state: absent, no network)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo" => "ppa:nginx/stable", "codename" => "jammy", "state" => "absent",
    })

    result["changed"].as_bool.must_equal(false)
    result["repo"].as_s.must_equal("deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main")
  end

  # Real Ansible's UbuntuSourcesList does `codename or distro.codename`, so
  # an empty-string codename falls back to the host codename (the
  # redis_cluster role ships the default `apt_repository_codename: ''` and
  # still ends up with a valid deb line). The plugin detects the fallback
  # from the spec host's own /etc/os-release, so pin the expected codename
  # to that file and skip where a host has none.
  it "falls back to the host codename when codename is an empty string (check mode)" do
    host_codename = File.read("/etc/os-release").each_line
      .find(&.starts_with?("VERSION_CODENAME="))
      .try(&.split('=', 2)[1].strip.strip('"').presence)
    skip("test host /etc/os-release has no VERSION_CODENAME") unless host_codename

    sources_list = PluginSpecHelper.tmp_path("codename-empty", "sources.list")
    list_d = PluginSpecHelper.tmp_path("codename-empty", "sources.list.d")
    FileUtils.mkdir_p(list_d)

    result = PluginSpecHelper.run("apt_repository", {
      "repo"                => "ppa:nginx/stable",
      "codename"            => "",
      "_ansible_check_mode" => "true",
      "_ppa_api_base"       => APT_REPO_LP_TEST_BASE,
      "_sources_list"       => sources_list,
      "_sources_list_d"     => list_d,
    })

    result["changed"].as_bool.must_equal(true)
    result["repo"].as_s.must_equal("deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu #{host_codename} main")
  end

  # Real apt_repository's sources_added/sources_removed: the full paths
  # of the sources files whose valid-line set appeared/disappeared with
  # the operation (its SourcesList dump keys, live-verified against
  # ansible-core 2.19.11). Adding a line to an EXISTING non-empty file
  # reports neither; a file created by the add lands in sources_added,
  # one emptied/deleted by the remove in sources_removed.
  describe "sources_added/sources_removed result fields" do
    it "lists the created file in sources_added when the add creates it" do
      sources_list, list_d = scratch_sources("added")
      dir = File.dirname(sources_list)

      result = PluginSpecHelper.run("apt_repository", {
        "repo"            => "deb https://packages.totally-fake-example.com/repo stable main",
        "filename"        => "fields-created",
        "update_cache"    => "false",
        "_sources_list"   => sources_list,
        "_sources_list_d" => list_d,
      })

      result["changed"].as_bool.must_equal(true)
      result["sources_added"].as_a.map(&.as_s).must_equal([File.join(list_d, "fields-created.list")])
      result["sources_removed"].as_a.must_be_empty
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reports neither field when the add appends to an existing non-empty file" do
      sources_list, list_d = scratch_sources("append")
      dir = File.dirname(sources_list)
      target = File.join(list_d, "fields-append.list")
      File.write(target, "deb https://already-there.example.com/repo stable main\n")

      result = PluginSpecHelper.run("apt_repository", {
        "repo"            => "deb https://second.example.com/repo stable main",
        "filename"        => "fields-append",
        "update_cache"    => "false",
        "_sources_list"   => sources_list,
        "_sources_list_d" => list_d,
      })

      result["changed"].as_bool.must_equal(true)
      result["sources_added"].as_a.must_be_empty
      result["sources_removed"].as_a.must_be_empty
      File.read_lines(target).size.must_equal(2)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "lists the file in sources_removed when the remove empties it" do
      sources_list, list_d = scratch_sources("removed")
      dir = File.dirname(sources_list)
      target = File.join(list_d, "fields-removed.list")
      File.write(target, "deb https://packages.totally-fake-example.com/repo stable main\n")

      result = PluginSpecHelper.run("apt_repository", {
        "repo"            => "deb https://packages.totally-fake-example.com/repo stable main",
        "state"           => "absent",
        "update_cache"    => "false",
        "_sources_list"   => sources_list,
        "_sources_list_d" => list_d,
      })

      result["changed"].as_bool.must_equal(true)
      result["sources_added"].as_a.must_be_empty
      result["sources_removed"].as_a.map(&.as_s).must_equal([target])
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reports neither field when the remove leaves other lines behind" do
      sources_list, list_d = scratch_sources("kept")
      dir = File.dirname(sources_list)
      target = File.join(list_d, "fields-kept.list")
      File.write(target, "deb https://packages.totally-fake-example.com/repo stable main\ndeb https://other.example.com/repo stable main\n")

      result = PluginSpecHelper.run("apt_repository", {
        "repo"            => "deb https://packages.totally-fake-example.com/repo stable main",
        "state"           => "absent",
        "update_cache"    => "false",
        "_sources_list"   => sources_list,
        "_sources_list_d" => list_d,
      })

      result["changed"].as_bool.must_equal(true)
      result["sources_added"].as_a.must_be_empty
      result["sources_removed"].as_a.must_be_empty
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reports both empty on an already-satisfied no-op" do
      sources_list, list_d = scratch_sources("noop")
      dir = File.dirname(sources_list)
      File.write(File.join(list_d, "fields-noop.list"), "deb https://packages.totally-fake-example.com/repo stable main\n")

      result = PluginSpecHelper.run("apt_repository", {
        "repo"            => "deb https://packages.totally-fake-example.com/repo stable main",
        "update_cache"    => "false",
        "_sources_list"   => sources_list,
        "_sources_list_d" => list_d,
      })

      result["changed"].as_bool.must_equal(false)
      result["sources_added"].as_a.must_be_empty
      result["sources_removed"].as_a.must_be_empty
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
