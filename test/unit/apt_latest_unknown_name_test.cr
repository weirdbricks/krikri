require "../minitest_helper"
require "file_utils"

# Issue #221 (lifeofguenter.virtualbox): a name the apt cache has never
# heard of - or one only referenced by other packages' dependencies, so
# `apt-cache policy` still prints a "Candidate: (none)" stanza while
# python-apt sees no versions and no providers - is a miss for BOTH
# state=latest and state=present: apt.py's install() resolves the name
# itself and fails "No package matching 'X' is available" before any
# apt-get call, with no cache_* keys, in normal and check mode alike -
# instead of surfacing apt-get's own "has no installation candidate"
# failure (live-verified vs ansible-playbook 2.19.11).

private def with_apt_unknown_name_shims(&)
  dir = PluginSpecHelper.tmp_path("fake-apt-unknown-name")
  log = PluginSpecHelper.tmp_path("apt-get-unknown-name-invocations")
  FileUtils.rm_r(dir) if File.exists?(dir)
  File.delete(log) if File.exists?(log)
  Dir.mkdir_p(dir)

  # A name only referenced by other packages' dependencies (the real
  # virtualbox-5.2 case) still gets a policy stanza, with no candidate.
  File.write(File.join(dir, "apt-cache"), "#!/bin/sh\nif [ \"$1\" = policy ]; then printf 'virtualbox-5.2:\\n  Installed: (none)\\n  Candidate: (none)\\n  Version table:\\n'; fi\nexit 0\n")
  File.write(File.join(dir, "dpkg-query"), "#!/bin/sh\nexit 0\n")
  File.write(File.join(dir, "apt-get"), "#!/bin/sh\necho \"$@\" >> \"#{log}\"\necho \"E: Package 'virtualbox-5.2' has no installation candidate\" >&2\nexit 100\n")
  ["apt-cache", "dpkg-query", "apt-get"].each do |name|
    File.chmod(File.join(dir, name), 0o755)
  end

  env = {"PATH" => "#{dir}:/usr/bin:/bin"}.to_json
  begin
    yield env, log
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

describe "apt with a name that has no candidate and no providers (issue 221)" do
  it "fails with No package matching and never calls apt-get" do
    with_apt_unknown_name_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "virtualbox-5.2",
        "state"        => "latest",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package matching 'virtualbox-5.2' is available")
      result.as_h.has_key?("cache_updated").must_equal(false)
      File.exists?(log).must_equal(false)
    end
  end

  it "fails state=present with no candidate and no providers, before apt-get" do
    with_apt_unknown_name_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "virtualbox-5.2",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package matching 'virtualbox-5.2' is available")
      result.as_h.has_key?("cache_updated").must_equal(false)
      File.exists?(log).must_equal(false)
    end
  end

  it "fails state=present in check mode with no candidate and no providers, before apt-get" do
    with_apt_unknown_name_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"                => "virtualbox-5.2",
        "state"               => "present",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package matching 'virtualbox-5.2' is available")
      result.as_h.has_key?("cache_updated").must_equal(false)
      File.exists?(log).must_equal(false)
    end
  end
end
