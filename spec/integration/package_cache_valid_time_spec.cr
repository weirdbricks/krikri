require "../spec_helper"
require "file_utils"

# Regression spec for `package:`'s cache-refresh-only path
# (`update_cache: true` with no `name:`, the buluma.security round-952553
# divergence). Real Ansible's `package:` delegates to the apt module on
# apt hosts, whose refresh is gated on `cache_valid_time:` staleness - a
# positive window the apt-cache mtime is still inside skips `apt-get
# update` entirely and exits changed=false. package.cr's
# `update_cache_only` never read `cache_valid_time:` at all and always
# ran the refresh, so a warm rerun inside the window still touched the
# apt lists and reported changed: true where real Ansible reported ok.
# apt.cr's own equivalent path (spec/integration/apt_cache_updated_spec.cr)
# already pins the correct behavior; this mirrors it for the
# OS-agnostic package plugin.

# Same stub-PATH shape as apt_cache_updated_spec: a stub dir whose
# `apt-get` records that it ran (marker file) and exits 0, and whose
# `stat` reports a controllable apt-cache mtime - simulating, without
# touching the real /var/lib/apt or needing root, exactly the freshness
# signal the plugin's cache_valid_time gate (and, when the refresh does
# run, its mtime-diff changed-reporting) reads. Yields the PATH value to
# embed in the plugin's `environment:` param.
private def with_stub_path(fresh : Bool, &) : Nil
  dir = File.join(Dir.tempdir, "krikri-package-cache-valid-#{Random.rand(1_000_000)}")
  marker = File.join(dir, "apt-get-called")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "apt-get"), "#!/bin/sh\ntouch \"$KRIKRI_FAKE_MARKER\"\nexit 0\n")
  stat_shim = fresh ? "#!/bin/sh\ndate +%s\n" : "#!/bin/sh\necho 100\n"
  File.write(File.join(dir, "stat"), stat_shim)
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "stat"), 0o755)
  yield "#{dir}:/usr/bin:/bin", marker
ensure
  FileUtils.rm_rf(dir) if dir
end

private def env_param(path : String, marker : String) : String
  {"PATH" => path, "KRIKRI_FAKE_MARKER" => marker}.to_json
end

# Real Ansible's apt module cannot run at all in check mode without the
# python3-apt bindings (same refusal package.cr's own cache-refresh-only
# path mirrors), so the stubbed-PATH runs below - which must get past
# that refusal to reach the gate under test - only mean anything on a
# spec host where the bindings import.
private def python_apt_available? : Bool
  Process.run("/usr/bin/python3", args: ["-c", "import apt"],
    output: Process::Redirect::Close, error: Process::Redirect::Close).success?
end

describe "package plugin cache-refresh-only cache_valid_time gate" do
  it "skips the refresh when the cache_valid_time window is still fresh (no apt-get update at all)" do
    next unless python_apt_available?

    with_stub_path(fresh: true) do |path, marker|
      result = PluginSpecHelper.run("package", {
        "use"                 => "apt",
        "update_cache"        => "true",
        "cache_valid_time"    => "600",
        "_ansible_check_mode" => "true",
        "_environment"        => env_param(path, marker),
      })

      result["changed"].as_bool.should be_false
      result["failed"]?.try(&.as_bool).should be_falsey
      # The whole point: a warm rerun inside the window must never
      # invoke apt-get update - with the pre-fix code the stub's marker
      # existed here, proving the refresh ran unconditionally.
      File.exists?(marker).should be_false
    end
  end

  it "still refreshes when the cache_valid_time window has gone stale" do
    next unless python_apt_available?

    with_stub_path(fresh: false) do |path, marker|
      result = PluginSpecHelper.run("package", {
        "use"                 => "apt",
        "update_cache"        => "true",
        "cache_valid_time"    => "600",
        "_ansible_check_mode" => "true",
        "_environment"        => env_param(path, marker),
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      File.exists?(marker).should be_true
    end
  end

  it "always refreshes with the default cache_valid_time: 0" do
    next unless python_apt_available?

    with_stub_path(fresh: false) do |path, marker|
      result = PluginSpecHelper.run("package", {
        "use"                 => "apt",
        "update_cache"        => "true",
        "_ansible_check_mode" => "true",
        "_environment"        => env_param(path, marker),
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      File.exists?(marker).should be_true
    end
  end
end
