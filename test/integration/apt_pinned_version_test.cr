require "../minitest_helper"
require "file_utils"

# Regression spec for `apt`'s `name: pkg=version` pin handling (round 76017,
# dj-wasabi.telegraf): `name: telegraf=1.18.2-1` where that exact version
# doesn't exist in the configured repos. Real package_status()'s
# version_installable probe (python-apt cache lookup, no apt-get involved)
# fails the task up front with "no available installation candidate for
# <spec>"; this engine previously let the task reach `apt-get install`
# (which hard-fails "E: Version '...' was not found", exit 100) and only
# reported a wrapped "Failed to install ..." msg - and an even older
# engine let the never-installed package "succeed" and fail later on its
# own missing files instead.

# Builds a stub PATH dir whose `apt-get` logs every invocation to
# $KRIKRI_APT_CALLS and answers an install of an explicitly pinned
# non-existent version ($KRIKRI_APT_BAD_PIN, "name=version") with real
# apt-get's own version-not-found failure shape (exit 100, the E: line on
# stderr); any other invocation exits 0. `apt-cache` (the candidate
# pre-flight probe's resolution source, standing in for Ansible's in-process
# python-apt cache) reports a candidate version that is NOT the bad pin,
# so the pin is what fails. `stat` reports a static mtime so the
# cache-update probe never sees movement. Yields the `_environment` JSON
# param and the call-log path.
private def with_bad_pin_shim(bad_pin : String, &)
  dir = File.join(Dir.tempdir, "krikri-apt-pin-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  apt_shim = <<-'SHIM'
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    case "$*" in
      *$KRIKRI_APT_BAD_PIN*)
        echo "E: Version '${KRIKRI_APT_BAD_PIN#*=}' for '${KRIKRI_APT_BAD_PIN%%=*}' was not found" >&2
        exit 100
        ;;
    esac
    exit 0
  SHIM
  File.write(File.join(dir, "apt-get"), apt_shim)
  File.write(File.join(dir, "apt-cache"), <<-'CACHE_SHIM')
    #!/bin/sh
    printf 'pkgname:\n  Installed: (none)\n  Candidate: 1.0-1\n  Version table:\n     1.0-1 500\n'
  CACHE_SHIM
  File.write(File.join(dir, "stat"), "#!/bin/sh\necho 100\n")
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "apt-cache"), 0o755)
  File.chmod(File.join(dir, "stat"), 0o755)
  env = {"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_APT_CALLS" => log, "KRIKRI_APT_BAD_PIN" => bad_pin}.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "apt plugin pinned-version validation" do
  # Real package_status()'s version_installable probe rejects a pin with
  # no candidate BEFORE any apt-get invocation, with its own wording -
  # apt-get's "E: Version '...' was not found" is never reached (this
  # engine used to defer the failure to apt-get and wrap it in a
  # "Failed to install ...: <stderr>" msg instead).
  it "fails the candidate pre-flight with Ansible's wording for a pinned version that doesn't exist" do
    with_bad_pin_shim("pkgname=badversion") do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "pkgname=badversion",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("no available installation candidate for pkgname=badversion")
      # The pre-flight rejects the pin before apt-get ever runs.
      install_calls = File.exists?(log) ? File.read_lines(log).select(&.starts_with?("install")) : [] of String
      install_calls.empty?.must_equal(true)
    end
  end

  # A wildcard pin matches against the cache's version table instead of
  # being rejected outright (round 1200000: nodejs=16.*, git=100:2.52.0*,
  # ntp=1:4.2.* all failed on hosts where the candidate existed).
  it "accepts a wildcard pin that matches a version in the cache table" do
    with_bad_pin_shim("pkgname=never-used") do |env, _log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "pkgname=1.*",
        "state"        => "present",
        "_environment" => env,
      })

      (result["failed"]?.try(&.as_bool?) || false).must_equal(false)
    end
  end

  it "still fails a wildcard pin that matches no version in the cache table" do
    with_bad_pin_shim("pkgname=never-used") do |env, _log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "pkgname=9.*",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("no available installation candidate for pkgname=9.*")
    end
  end
end

# Stub PATH dir like with_bad_pin_shim, but `apt-cache policy` prints a
# realistic full stanza (package header, Installed:/Candidate: lines, the
# Version table's version row AND a deeper-indented mirror row) and
# `apt-get` logs every invocation and exits 0.
private def with_htop_policy_shim(&)
  dir = File.join(Dir.tempdir, "krikri-apt-htop-policy-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "apt-get"), <<-'SHIM')
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    exit 0
  SHIM
  File.write(File.join(dir, "apt-cache"), <<-'CACHE_SHIM')
    #!/bin/sh
    printf 'htop:\n  Installed: (none)\n  Candidate: 3.4.1-5\n  Version table:\n     3.4.1-5 500\n        500 https://deb.debian.org/debian trixie/main amd64 Packages\n'
  CACHE_SHIM
  File.write(File.join(dir, "stat"), "#!/bin/sh\necho 100\n")
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "apt-cache"), 0o755)
  File.chmod(File.join(dir, "stat"), 0o755)
  env = {"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_APT_CALLS" => log}.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "apt plugin wildcard pin version-table resolution" do
  # A wildcard pin must fnmatch the version table's rows only:
  # apt-cache policy's package header, Installed:/Candidate: lines and
  # mirror rows are not versions, and a `*` pin used to match the header
  # first, handing apt-get `htop=htop:` ("Version 'htop:' ... was not
  # found", exit 2).
  it "resolves a wildcard pin to a version-table row, never the package header" do
    with_htop_policy_shim do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "htop=*",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool?).must_be_nil
      install_calls = File.exists?(log) ? File.read_lines(log).select(&.includes?(" install ")) : [] of String
      install_calls.size.must_equal(1)
      install_calls[0].includes?("htop=3.4.1-5").must_equal(true)
      install_calls[0].includes?("htop:").must_equal(false)
    end
  end
end

# state=latest's own wildcard-pin handling: real install() fnmatches the
# pin against the INSTALLED version first, so an installed `bash=5.*` on a
# 5.2-1 host is a no-op with no apt-get call at all, and otherwise the
# concrete cache version (`bash=5.2-1`) - never the raw glob - is what
# reaches the apt-get command line.

# Stub PATH dir: `dpkg-query` reports bash installed at $KRIKRI_APT_INSTALLED
# (unset = not installed, real dpkg-query's empty-stdout exit-1 shape for an
# unknown name), `apt-cache policy` carries 5.2-1 in its version table (the
# stand-in for Ansible's in-process cache lookup), `apt-get` logs every
# invocation to $KRIKRI_APT_CALLS and exits 0 with no output (no summary
# line, so the plugin's was_upgraded fallback reads exit code 0 as
# "upgraded"), `stat` reports a static mtime.
private def with_latest_wildcard_shim(installed_version : String, &)
  dir = File.join(Dir.tempdir, "krikri-apt-latest-wild-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  apt_shim = <<-'SHIM'
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    exit 0
  SHIM
  dpkg_shim = <<-'SHIM'
    #!/bin/sh
    if [ -n "$KRIKRI_APT_INSTALLED" ]; then
      echo "ii  $KRIKRI_APT_INSTALLED bash"
      exit 0
    fi
    exit 1
  SHIM
  File.write(File.join(dir, "apt-get"), apt_shim)
  File.write(File.join(dir, "dpkg-query"), dpkg_shim)
  File.write(File.join(dir, "apt-cache"), <<-'CACHE_SHIM')
    #!/bin/sh
    printf 'bash:\n  Installed: (none)\n  Candidate: 5.2-1\n  Version table:\n     5.2-1 500\n'
  CACHE_SHIM
  File.write(File.join(dir, "stat"), "#!/bin/sh\necho 100\n")
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "dpkg-query"), 0o755)
  File.chmod(File.join(dir, "apt-cache"), 0o755)
  File.chmod(File.join(dir, "stat"), 0o755)
  env = {"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_APT_CALLS" => log, "KRIKRI_APT_INSTALLED" => installed_version}.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "apt plugin state=latest wildcard pin handling" do
  # Installed at a version the glob fnmatches: real install()'s
  # package_status() short-circuit makes this a plain no-op - changed:
  # false and no apt-get invocation, where this engine used to run
  # `apt-get install 'bash=5.*'` and fail on the raw glob.
  it "treats a wildcard pin matching the installed version as a no-op without calling apt-get" do
    with_latest_wildcard_shim("5.2-1") do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "bash=5.*",
        "state"        => "latest",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool?).must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Package bash=5.* already at latest version")
      apt_get_calls = File.exists?(log) ? File.read_lines(log) : [] of String
      apt_get_calls.select(&.includes?(" install ")).empty?.must_equal(true)
    end
  end

  # Installed BELOW the glob's match (4.x installed, pin wants 5.*): the
  # pin is resolved against the cache's version table and the concrete
  # version is pinned onto the apt-get spec, never the raw pattern.
  it "passes the resolved concrete version, not the glob, to apt-get" do
    with_latest_wildcard_shim("4.3-1") do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "bash=5.*",
        "state"        => "latest",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool?).must_be_nil
      result["changed"].as_bool.must_equal(true)
      install_calls = File.exists?(log) ? File.read_lines(log).select(&.includes?(" install ")) : [] of String
      install_calls.size.must_equal(1)
      install_calls[0].includes?("bash=5.2-1").must_equal(true)
      install_calls[0].includes?("bash=5.*").must_equal(false)
    end
  end

  # The installed version doesn't match the glob and the cache table has
  # no matching version either: install()'s own pre-apt-get failure, the
  # wording handle_install already produces - apt-get itself is never
  # reached with the unresolvable spec.
  it "fails a wildcard pin matching no installed or cache version with Ansible's wording" do
    with_latest_wildcard_shim("5.2-1") do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "bash=9.*",
        "state"        => "latest",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("no available installation candidate for bash=9.*")
      apt_get_calls = File.exists?(log) ? File.read_lines(log) : [] of String
      apt_get_calls.select(&.includes?(" install ")).empty?.must_equal(true)
    end
  end
end
