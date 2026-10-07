require "../minitest_helper"
require "file_utils"

# Regression spec for iroquoisorg.tools round 2300027: `apt: state=latest`
# on a PURELY VIRTUAL package name (jammy's git-core, Provided only by
# git). Real package_status() resolves a virtual name through its lone
# installed provider and pins the PROVIDER's candidate version onto the
# requested (virtual) name - `install 'git-core=1:2.34.1-1ubuntu1.17'` -
# which apt-get itself refuses ("E: Version '...' for 'git-core' was not
# found", rc=100), so the task FAILS. This engine used to pass the bare
# virtual name through, letting apt-get silently upgrade the provider and
# report changed.
#
# The plugin wiring is tested through the real plugin binary with fake
# `apt-cache`/`dpkg-query`/`apt-get` shims on PATH, injected via the
# `_environment` param (same pattern as apt_pinned_version_test.cr - no
# process-wide ENV mutation). Every apt-get subcommand except `install`
# is refused loudly so the suite can never mutate the real system through
# it, and `install` always fails rc=100 while logging its argv - the pin
# under test is observable in that log and in the failure msg without any
# real package operation.

private def with_apt_virtual_pin_shims(provider_installed : Bool, &)
  dir = PluginSpecHelper.tmp_path("fake-apt-virtual-pin")
  log = PluginSpecHelper.tmp_path("apt-get-invocations")
  FileUtils.rm_r(dir) if File.exists?(dir)
  File.delete(log) if File.exists?(log)
  Dir.mkdir_p(dir)

  apt_cache_shim = <<-'SH'
    #!/bin/sh
    case "$1 $2" in
      "policy git-core")
        printf 'git-core:\n  Installed: (none)\n  Candidate: (none)\n  Version table:\n'
        ;;
      "policy git")
        printf 'git:\n  Installed: 1:2.34.1-1ubuntu1.10\n  Candidate: 1:2.34.1-1ubuntu1.17\n  Version table:\n *** 1:2.34.1-1ubuntu1.17 500\n        500 http://archive.ubuntu.com/ubuntu jammy/main amd64 Packages\n'
        ;;
      "showpkg git-core")
        printf 'Package: git-core\nVersions: \n\nReverse Provides: \ngit 1:2.34.1-1ubuntu1.17 (= )\n'
        ;;
      *)
        echo "fake apt-cache shim: refusing $*" >&2
        exit 99
        ;;
    esac
    SH
  dpkg_query_shim = <<-'SH'
    #!/bin/sh
    if [ "$KRIKRI_APT_PROVIDER_STATUS" = "installed" ]; then
      printf 'ii  1:2.34.1-1ubuntu1.10 git\n'
    fi
    exit 0
    SH
  apt_get_shim = <<-SH
    #!/bin/sh
    echo "$@" >> "#{log}"
    case "$*" in
      *install*)
        echo "E: Version '1:2.34.1-1ubuntu1.17' for 'git-core' was not found" >&2
        exit 100
        ;;
    esac
    echo "fake apt-get shim: refusing subcommand $1" >&2
    exit 99
    SH
  File.write(File.join(dir, "apt-cache"), apt_cache_shim)
  File.write(File.join(dir, "dpkg-query"), dpkg_query_shim)
  File.write(File.join(dir, "apt-get"), apt_get_shim)
  ["apt-cache", "dpkg-query", "apt-get"].each do |name|
    File.chmod(File.join(dir, name), 0o755)
  end

  env = {
    "PATH"                       => "#{dir}:/usr/bin:/bin",
    "KRIKRI_APT_CALLS"           => log,
    "KRIKRI_APT_PROVIDER_STATUS" => provider_installed ? "installed" : "absent",
  }.to_json
  begin
    yield env, log
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

describe "apt virtual-package provider pin (round 2300027)" do
  it "pins state=latest virtual names to the lone installed provider's candidate, failing like real" do
    with_apt_virtual_pin_shims(provider_installed: true) do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "git-core",
        "state"        => "latest",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include(
        "install 'git-core=1:2.34.1-1ubuntu1.17'' failed: E: Version '1:2.34.1-1ubuntu1.17' for 'git-core' was not found"
      )
      # The pin is on the VIRTUAL name, exactly as real's install() builds it
      # (the shim's log carries the shell-unquoted argv, the msg the quoted one).
      File.read(log).must_include("install git-core=1:2.34.1-1ubuntu1.17")
    end
  end

  it "keeps the bare virtual-name spec when the lone provider is not installed" do
    with_apt_virtual_pin_shims(provider_installed: false) do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "git-core",
        "state"        => "latest",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      File.read(log).must_include("install git-core")
      File.read(log).wont_include("git-core=1:2.34.1-1ubuntu1.17")
    end
  end
end
