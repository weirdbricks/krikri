require "../spec_helper"
require "file_utils"

# apt_repository writes to /etc/apt/sources.list.d/, which needs root -
# the earlier specs exercise check_mode only (read-only, safe on a real
# machine); the sources_added/sources_removed ones write for real but
# through the plugin's `_sources_list`/`_sources_list_d` scratch-dir
# seams (same convention as spec/integration/apt_repository_param_coverage_spec.cr),
# so nothing here touches /etc/apt either.
private def scratch_sources(tag : String) : {String, String}
  dir = File.join(Dir.tempdir, "krikri-aptrepo-fields-#{tag}-#{Random.rand(1_000_000)}")
  list_d = File.join(dir, "sources.list.d")
  Dir.mkdir_p(list_d)
  {File.join(dir, "sources.list"), list_d}
end

describe "apt_repository plugin" do
  it "reports it would add a repository that isn't present yet (check mode, no real change)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"       => "deb https://packages.totally-fake-example.com/repo stable main",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    result["state"].as_s.should eq("present")
  end

  it "normalizes whitespace before checking/reporting the repo line" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"       => "  deb   https://packages.totally-fake-example.com/repo   stable main  ",
      "_ansible_check_mode" => "true",
    })

    result["repo"].as_s.should eq("deb https://packages.totally-fake-example.com/repo stable main")
  end

  it "reports it would remove a repository when state: absent and it isn't present (no-op either way, safe even without check mode)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"  => "deb https://packages.totally-fake-example.com/repo stable main",
      "state" => "absent",
    })

    result["changed"].as_bool.should be_false
    result["state"].as_s.should eq("absent")
  end

  it "fails with a clear message when repo is missing" do
    result = PluginSpecHelper.run("apt_repository", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("repo")
  end

  it "fails with a clear message for a line that isn't deb/deb-src or ppa:" do
    result = PluginSpecHelper.run("apt_repository", {"repo" => "not a valid repo line"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Invalid repo line")
  end

  # ppa: shorthand (see plugins/apt_repository.cr's own class doc for the
  # full formula breakdown - expands to a real deb line, fetches a
  # signing key from the real Launchpad API over HTTP, and exports it via
  # gpg). The two paths below never reach the network at all - matching
  # real Ansible's own behavior exactly (check_mode and an
  # already-satisfied state: absent both return before ever calling
  # _get_ppa_info) - so they're safe to exercise for real, unlike a
  # genuine PPA add/remove which would need real internet access and
  # write access to /etc/apt/. The actual network+GPG path was verified
  # by hand in a container instead - see git log.
  it "expands ppa: to the exact real-Ansible deb line shape and reports it would add (check mode, no network)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo" => "ppa:nginx/stable", "codename" => "jammy", "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.should be_true
    result["repo"].as_s.should eq("deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main")
  end

  it "reports a ppa: repository already absent as a no-op (state: absent, no network)" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo" => "ppa:nginx/stable", "codename" => "jammy", "state" => "absent",
    })

    result["changed"].as_bool.should be_false
    result["repo"].as_s.should eq("deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main")
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

      result["changed"].as_bool.should be_true
      result["sources_added"].as_a.map(&.as_s).should eq([File.join(list_d, "fields-created.list")])
      result["sources_removed"].as_a.should be_empty
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

      result["changed"].as_bool.should be_true
      result["sources_added"].as_a.should be_empty
      result["sources_removed"].as_a.should be_empty
      File.read_lines(target).size.should eq(2)
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

      result["changed"].as_bool.should be_true
      result["sources_added"].as_a.should be_empty
      result["sources_removed"].as_a.map(&.as_s).should eq([target])
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

      result["changed"].as_bool.should be_true
      result["sources_added"].as_a.should be_empty
      result["sources_removed"].as_a.should be_empty
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

      result["changed"].as_bool.should be_false
      result["sources_added"].as_a.should be_empty
      result["sources_removed"].as_a.should be_empty
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
