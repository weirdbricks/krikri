require "../minitest_helper"
require "file_utils"

# Issue #1102 (fede2cr.alfresco52): `apt: state=present` on a PURELY
# VIRTUAL package name whose lone provider is installed - libglu-dev,
# Provided only by libglu1-mesa-dev - reported changed in CHECK mode
# where real ansible reports ok. apt.py's package_status() resolves the
# virtual name through that one provider and, since it is installed,
# never puts the name on the apt-get command line at all; this engine's
# installed pre-check only ever looked the literal name up in dpkg, so a
# satisfied virtual name always fell through to the check-mode
# `apt-get install --simulate` run, whose reached-apt-get result is
# changed=true (live-verified vs ansible-playbook 2.21.6: libparted2,
# provided solely by the installed libparted2t64, is ok there).
#
# The plugin is driven through the real plugin binary with fake
# `apt-cache`/`dpkg-query`/`apt-get` shims on PATH (the
# apt_virtual_pin_test.cr pattern - no process-wide ENV mutation).
# `apt-get` logs its argv and can never reach the real system.

private def with_apt_virtual_present_shims(provider_installed : Bool, &)
  dir = PluginSpecHelper.tmp_path("fake-apt-virtual-present")
  log = PluginSpecHelper.tmp_path("apt-get-virtual-present-invocations")
  FileUtils.rm_r(dir) if File.exists?(dir)
  File.delete(log) if File.exists?(log)
  Dir.mkdir_p(dir)

  apt_cache_shim = <<-'SH'
    #!/bin/sh
    case "$1 $2" in
      "policy libglu-dev")
        printf 'libglu-dev:\n  Installed: (none)\n  Candidate: (none)\n  Version table:\n'
        ;;
      "showpkg libglu-dev")
        printf 'Package: libglu-dev\nVersions: \n\nReverse Provides: \nlibglu1-mesa-dev 9.0.0-1ubuntu1 (= 9.0.0-1ubuntu1)\n'
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
      case "$*" in
        *libglu1-mesa-dev*) printf 'ii  9.0.0-1ubuntu1 libglu1-mesa-dev\n' ;;
      esac
    fi
    exit 0
    SH
  apt_get_shim = <<-SH
    #!/bin/sh
    echo "$@" >> "#{log}"
    echo "0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded."
    exit 0
    SH
  File.write(File.join(dir, "apt-cache"), apt_cache_shim)
  File.write(File.join(dir, "dpkg-query"), dpkg_query_shim)
  File.write(File.join(dir, "apt-get"), apt_get_shim)
  ["apt-cache", "dpkg-query", "apt-get"].each do |name|
    File.chmod(File.join(dir, name), 0o755)
  end

  env = {
    "PATH"                       => "#{dir}:/usr/bin:/bin",
    "KRIKRI_APT_PROVIDER_STATUS" => provider_installed ? "installed" : "absent",
  }.to_json
  begin
    yield env, log
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

describe "apt state=present on a virtual name whose lone provider is installed (issue 1102)" do
  it "reports ok in check mode without ever running apt-get" do
    with_apt_virtual_present_shims(provider_installed: true) do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"                => "libglu-dev",
        "state"               => "present",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(false)
      result.as_h.has_key?("failed").must_equal(false)
      File.exists?(log).must_equal(false)
    end
  end

  it "still runs apt-get in check mode when the lone provider is absent" do
    with_apt_virtual_present_shims(provider_installed: false) do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"                => "libglu-dev",
        "state"               => "present",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(true)
      # Real's "let apt-get sort it out" path passes the name bare - the
      # virtual name has no candidate version of its own to pin.
      File.read(log).must_include("install libglu-dev")
      File.read(log).wont_include("libglu-dev=")
    end
  end
end
