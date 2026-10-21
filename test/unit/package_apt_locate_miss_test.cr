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
# Issue #195 extends that to the other unresolvable-name shape: "E:
# Package 'X' has no installation candidate". ansible's apt.py resolves
# the name itself (cache[X] plus get_providing_packages) BEFORE apt-get
# runs, so it fails with its own "No package matching 'X' is available"
# both when every listed provider lacks a candidate (apt-get stdout
# lists the providers, each tagged "[Not candidate version]") and when
# the name has no providers at all - apt-get prints the same E: line
# then, but with NO provider listing. One provider with a candidate
# sends the task to apt-get, keeping the raw result. The deliberate
# exception is a name with a dpkg status record but no repo candidate
# (a config-files "rc" remnant): python-apt's cache lookup succeeds
# there and real ansible says "no available installation candidate for
# X" instead, so the plugin guards the mapping with a dpkg-record check
# on the failure path - the test host has no dpkg record for the
# shimmed name, so the shim tests below exercise the mapping itself.
#
# The plugin binary is exercised for real against a shimmed apt-get on
# PATH (same pattern as dnf_install_failure_shape_test.cr's fake dnf),
# because the locate-miss detection lives inside the plugin file whose
# bottom-of-file entry point defeats a plain require.

APT_LOCATE_MISS_STDERR = "E: Unable to locate package krikri-no-such-pkg-194\n"
# A failure apt.py's candidate resolution can't produce (it only
# resolves names; repo-level breakage surfaces from apt-get itself).
APT_BROKEN_REPO_STDERR               = "E: The repository 'http://example.com/debian broken Release' does not have a Release file.\n"
APT_NO_CANDIDATE_STDERR              = "E: Package 'krikri-virtual-pkg-195' has no installation candidate\n"
APT_VIRTUAL_ALL_NOT_CANDIDATE_STDOUT = "Reading package lists...\nBuilding dependency tree...\nPackage krikri-virtual-pkg-195 is a virtual package provided by:\n  krikri-fake-provider-a 1.0-1 [Not candidate version]\n  krikri-fake-provider-b 2.0-1 [Not candidate version]\n\n0 upgraded, 0 newly installed\n"
APT_VIRTUAL_ONE_CANDIDATE_STDOUT     = "Reading package lists...\nBuilding dependency tree...\nPackage krikri-virtual-pkg-195 is a virtual package provided by:\n  krikri-fake-provider-a 1.0-1\n  krikri-fake-provider-b 2.0-1 [Not candidate version]\n\n0 upgraded, 0 newly installed\n"
APT_NO_LISTING_STDOUT                = "Reading package lists...\nBuilding dependency tree...\n0 upgraded, 0 newly installed\n"

private def with_failing_apt_get_shim(stderr : String, stdout : String = "", &)
  shim_dir = PluginSpecHelper.tmp_path("fake-apt-get-fail")
  Dir.mkdir_p(shim_dir)
  # The stdout heredoc's terminator must sit on its own line: the <<- literals
  # above carry no trailing newline, so the newline before the terminator is
  # added here, or the stderr heredoc would be swallowed into stdout.
  script = "cat <<'KRIKRI_FAKE_APT_EOF'\n#{stdout}\nKRIKRI_FAKE_APT_EOF\ncat <<'KRIKRI_FAKE_APT_EOF' >&2\n#{stderr}KRIKRI_FAKE_APT_EOF\nexit 100\n"
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

describe "package:/apt locate-miss failure shape (issues 194 and 195)" do
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

  it "reports No package matching for a virtual package whose providers all lack candidates (present)" do
    with_failing_apt_get_shim(APT_NO_CANDIDATE_STDERR, APT_VIRTUAL_ALL_NOT_CANDIDATE_STDOUT) do
      result = PluginSpecHelper.run("package",
        {"name" => "krikri-virtual-pkg-195", "state" => "present", "use" => "apt"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package matching 'krikri-virtual-pkg-195' is available")
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end

  it "reports No package matching for a virtual package whose providers all lack candidates (latest)" do
    with_failing_apt_get_shim(APT_NO_CANDIDATE_STDERR, APT_VIRTUAL_ALL_NOT_CANDIDATE_STDOUT) do
      result = PluginSpecHelper.run("package",
        {"name" => "krikri-virtual-pkg-195", "state" => "latest", "use" => "apt"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package matching 'krikri-virtual-pkg-195' is available")
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end

  it "keeps the raw Failed to install result when a virtual provider has a candidate" do
    with_failing_apt_get_shim(APT_NO_CANDIDATE_STDERR, APT_VIRTUAL_ONE_CANDIDATE_STDOUT) do
      result = PluginSpecHelper.run("package",
        {"name" => "krikri-virtual-pkg-195", "state" => "present", "use" => "apt"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to install krikri-virtual-pkg-195: #{APT_NO_CANDIDATE_STDERR}")
      result.as_h.has_key?("stderr").must_equal(true)
    end
  end

  it "reports No package matching for a no-candidate failure without a provider listing" do
    with_failing_apt_get_shim(APT_NO_CANDIDATE_STDERR, APT_NO_LISTING_STDOUT) do
      result = PluginSpecHelper.run("package",
        {"name" => "krikri-virtual-pkg-195", "state" => "present", "use" => "apt"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package matching 'krikri-virtual-pkg-195' is available")
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end
end
