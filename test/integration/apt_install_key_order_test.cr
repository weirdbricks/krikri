require "../minitest_helper"
require "file_utils"

# Regression spec for the apt plugin's install-path registered-result
# KEY ORDER and key SET, pinned against Ansible.builtin.apt on a
# real Ubuntu 22.04 host (krikri-role-tester rounds 992002/992003,
# kop_firewall/kop_storage *_helper_install probes; the real side of
# those captures is the oracle here):
#
# - an all-already-installed package list (nothing reaches apt-get):
#   [changed, cache_updated, cache_update_time, failed] - no
#   stdout/stderr/msg/stdout_lines/stderr_lines;
# - a package that actually installs: [changed, stdout, stderr, diff,
#   cache_updated, cache_update_time, stdout_lines, stderr_lines,
#   failed] - still no msg, and `diff` present even with diff mode off
#   (a bare {} there, apt.py parse_diff's {prepared: ...} slice when
#   on).
#
# PluginSpecHelper.run returns the plugin's raw wire JSON; the
# controller backfills `failed` (false) after these keys, which is why
# the assertions below stop at the plugin-emitted keys.

private def with_apt_shims(dpkg_status : String, install_output : String, &)
  dir = File.join(Dir.tempdir, "krikri-apt-keyorder-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  apt_shim = "#!/bin/sh\ncase \"$*\" in *update*) ;; *) printf '%b' \"#{install_output.gsub("\"", "\\\"")}\" ;; esac\nexit 0\n"
  File.write(File.join(dir, "apt-get"), apt_shim)
  File.write(File.join(dir, "dpkg-query"), "#!/bin/sh\necho \"$KRIKRI_DPKG_STATUS 1.0-1 $3\"\n")
  File.write(File.join(dir, "stat"), "#!/bin/sh\ndate +%s\n")
  File.write(File.join(dir, "apt-cache"), "#!/bin/sh\n[ -n \"$2\" ] || exit 0\nprintf '%s:\\n  Installed: (none)\\n  Candidate: 1.0-1\\n  Version table:\\n' \"$2\"\n")
  {"apt-get", "dpkg-query", "stat", "apt-cache"}.each { |bin| File.chmod(File.join(dir, bin), 0o755) }
  env = {
    "PATH"               => "#{dir}:/usr/bin:/bin",
    "KRIKRI_DPKG_STATUS" => dpkg_status,
  }.to_json
  yield env
ensure
  FileUtils.rm_rf(dir) if dir
end

# The dpkg-query shim reports the state word from $KRIKRI_DPKG_STATUS
# ("ii" installed / "un" not installed); apt-cache policy answers with a
# candidate for any name, so the candidate pre-flight passes.

describe "apt plugin install-path result key order (real round-992002/992003 shape)" do
  it "serializes an all-already-installed install as the bare changed-cache_updated-cache_update_time shape" do
    with_apt_shims("ii", "") do |env|
      result = PluginSpecHelper.run("apt", {
        "name"             => "krikri-fake-pkg",
        "state"            => "present",
        "update_cache"     => "true",
        "cache_valid_time" => "999999999",
        "_environment"     => env,
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["cache_updated"].as_bool.must_equal(false)
      # The lists-dir mtime (stat shim echoes the current epoch), carried
      # even though nothing needed updating.
      ((result["cache_update_time"].as_i? || 0) > 0).must_equal(true)
      # No stdout/stderr/msg - and therefore no controller-appended
      # stdout_lines/stderr_lines either.
      result["stdout"]?.must_be_nil
      result["stderr"]?.must_be_nil
      result["msg"]?.must_be_nil
      result.as_h.keys.must_equal(["changed", "cache_updated", "cache_update_time"])
    end
  end

  it "serializes an install that ran apt-get as changed-stdout-stderr-diff-cache keys, with no msg" do
    output = "Reading package lists...\\nBuilding dependency tree...\\nReading state information...\\nThe following NEW packages will be installed:\\n  krikri-fake-pkg\\n0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.\\n"
    with_apt_shims("un", output) do |env|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-fake-pkg",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"]?.must_be_nil
      result["stdout"].as_s.must_equal(output.gsub("\\n", "\n"))
      result["stderr"].as_s.must_equal("")
      # diff mode off: real apt.py still carries the key, as a bare {}.
      result["diff"].as_h.keys.must_equal([] of String)
      ((result["cache_update_time"].as_i? || 0) > 0).must_equal(true)
      # stdout_lines/stderr_lines are emitted module-side (like the
      # command/shell plugins) so the registered order puts them before
      # the controller's failed backfill, exactly like real.
      result["stdout_lines"].as_a.must_equal(["Reading package lists...", "Building dependency tree...", "Reading state information...", "The following NEW packages will be installed:", "  krikri-fake-pkg", "0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded."])
      result["stderr_lines"].as_a.must_equal([] of String)
      result.as_h.keys.must_equal(["changed", "stdout", "stderr", "diff", "cache_updated", "cache_update_time", "stdout_lines", "stderr_lines"])
    end
  end

  it "fills diff with apt.py parse_diff's prepared slice when diff mode is on" do
    output = "Reading package lists...\\nBuilding dependency tree...\\nReading state information...\\nThe following NEW packages will be installed:\\n  krikri-fake-pkg\\n0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.\\nSetting up krikri-fake-pkg (1.0-1)...\\n"
    with_apt_shims("un", output) do |env|
      result = PluginSpecHelper.run("apt", {
        "name"          => "krikri-fake-pkg",
        "state"         => "present",
        "_ansible_diff" => "true",
        "_environment"  => env,
      })

      prepared = result["diff"].as_h["prepared"].as_s
      # Everything after the "Reading state information..." marker up to
      # and including the "N upgraded" summary line.
      prepared.must_equal("The following NEW packages will be installed:\\n  krikri-fake-pkg\\n0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.".gsub("\\n", "\n"))
    end
  end

  it "serializes a check-mode install with the same key set as a real install" do
    with_apt_shims("un", "") do |env|
      result = PluginSpecHelper.run("apt", {
        "name"                => "krikri-fake-pkg",
        "state"               => "present",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"]?.must_be_nil
      result.as_h.keys.must_equal(["changed", "stdout", "stderr", "diff", "cache_updated", "cache_update_time", "stdout_lines", "stderr_lines"])
    end
  end
end
