require "../minitest_helper"
require "file_utils"
require "json"

# A version-pinned `NAME=VER` request whose version has no candidate:
# ansible resolves each pin against the apt cache BEFORE apt-get runs
# and fails the task with its own "no available installation candidate
# for NAME=VER" (plus cache_updated/cache_update_time, no stderr key -
# live-verified against ansible-playbook 2.19, figlet=0.0.1* and
# docker-ce=17.06*). krikri's package: only sees the miss through
# apt-get's exit-100 stderr "E: Version 'VER' for 'NAME' was not
# found", so the install-failure branch maps that shape onto ansible's
# message; cache_updated mirrors whether THIS task's own refresh ran.
#
# The plugin binary is exercised for real against a shimmed apt-get on
# PATH (same pattern as package_apt_locate_miss_test.cr, whose helper
# is copied rather than required - the locate-miss detection lives
# inside the plugin file whose bottom-of-file entry point defeats a
# plain require).

APT_VERSION_MISS_STDERR = "E: Version '0.0.1*' for 'krikri-pkg-573' was not found\n"

private def with_failing_apt_get_shim(stderr : String, update_ok : Bool = false, &)
  shim_dir = PluginSpecHelper.tmp_path("fake-apt-get-version-miss")
  Dir.mkdir_p(shim_dir)
  # With update_ok the shim lets `apt-get update` (the cache refresh)
  # succeed and saves the version-not-found failure for the install
  # call, so the task exercises cache_updated=true end to end.
  script = update_ok ? "if [ \"$1\" = \"update\" ]; then exit 0; fi\ncat <<'KRIKRI_FAKE_APT_EOF' >&2\n#{stderr}KRIKRI_FAKE_APT_EOF\nexit 100\n" : "cat <<'KRIKRI_FAKE_APT_EOF' >&2\n#{stderr}KRIKRI_FAKE_APT_EOF\nexit 100\n"
  File.write("#{shim_dir}/apt-get", script)
  File.chmod("#{shim_dir}/apt-get", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "package:/apt version-pin miss failure shape" do
  serial!

  it "reports no available installation candidate for a pinned name apt can't resolve" do
    with_failing_apt_get_shim(APT_VERSION_MISS_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "krikri-pkg-573=0.0.1*", "state" => "present", "use" => "apt"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("no available installation candidate for krikri-pkg-573=0.0.1*")
      result["cache_updated"].as_bool.must_equal(false)
      result.as_h.has_key?("cache_update_time").must_equal(true)
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end

  it "reports cache_updated true when the task's own refresh ran before the pin miss" do
    with_failing_apt_get_shim(APT_VERSION_MISS_STDERR, update_ok: true) do
      result = PluginSpecHelper.run("package",
        {"name" => "krikri-pkg-573=0.0.1*", "state" => "present", "use" => "apt", "update_cache" => "true"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("no available installation candidate for krikri-pkg-573=0.0.1*")
      result["cache_updated"].as_bool.must_equal(true)
      result.as_h.has_key?("cache_update_time").must_equal(true)
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end
end
