require "../minitest_helper"
require "file_utils"
require "json"

# Issue #194: `package:` (apt backend) failed a nonexistent-package
# install with its raw shape - msg "Failed to install X: E: Unable to
# locate package X" plus a stderr key - while ansible-playbook resolves
# each requested name against the apt cache BEFORE running apt-get and
# fails the task with apt.py's own "No package matching 'X' is
# available" and no stderr key (live-verified against ansible-playbook
# 2.19.11). apt.cr already produced that wording via its own candidate
# resolution; package: only sees the miss through apt-get's stderr, so
# it maps the "E: Unable to locate package" shape onto apt.py's message.
#
# The plugin binary is exercised for real against a shimmed apt-get on
# PATH (same pattern as dnf_install_failure_shape_test.cr's fake dnf),
# because the locate-miss detection lives inside the plugin file whose
# bottom-of-file entry point defeats a plain require.

APT_LOCATE_MISS_STDERR = "E: Unable to locate package krikri-no-such-pkg-194\n"
# A failure apt.py's candidate resolution can't produce (it only
# resolves names; repo-level breakage surfaces from apt-get itself).
APT_BROKEN_REPO_STDERR = "E: The repository 'http://example.com/debian broken Release' does not have a Release file.\n"

private def with_failing_apt_get_shim(stderr : String, &)
  shim_dir = PluginSpecHelper.tmp_path("fake-apt-get-fail")
  Dir.mkdir_p(shim_dir)
  script = "cat <<'KRIKRI_FAKE_APT_EOF' >&2\n#{stderr}KRIKRI_FAKE_APT_EOF\nexit 100\n"
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

describe "package:/apt locate-miss failure shape (issue 194)" do
  serial!

  it "reports No package matching for a state: present name apt can't locate" do
    with_failing_apt_get_shim(APT_LOCATE_MISS_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "krikri-no-such-pkg-194", "state" => "present", "use" => "apt"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("No package matching 'krikri-no-such-pkg-194' is available")
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end

  it "reports No package matching for a state: latest name apt can't locate" do
    with_failing_apt_get_shim(APT_LOCATE_MISS_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "krikri-no-such-pkg-194", "state" => "latest", "use" => "apt"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package matching 'krikri-no-such-pkg-194' is available")
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end

  it "keeps the raw Failed to install result for non-locate-miss failures" do
    with_failing_apt_get_shim(APT_BROKEN_REPO_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "krikri-no-such-pkg-194", "state" => "present", "use" => "apt"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to install krikri-no-such-pkg-194: #{APT_BROKEN_REPO_STDERR}")
      result.as_h.has_key?("stderr").must_equal(true)
    end
  end
end
