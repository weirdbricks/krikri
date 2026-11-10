require "../minitest_helper"
require "file_utils"
require "json"

# Issue #1098 (acandid.bind, Rocky 9 --check): `yum: {name: [bind,
# bind-utils], state: latest}` with the packages already installed AND
# already at the latest version read `changed` under --check where real
# ansible-playbook read `ok`. Real resolves the whole goal BEFORE its
# check-mode stop (dnf.py resolves, then exits before do_transaction),
# so an already-at-latest batch resolves to dnf's empty "Nothing to do"
# transaction - only a batch with an actually-available upgrade is
# changed. This engine used to report the blanket "would update" for
# every installed name in an update-shaped transaction without ever
# asking the package manager whether an upgrade exists. The same
# blanket-changed lived in the `update_only` + `state: present` check
# path (real reports ok, msg "Nothing to do", for an already-latest
# batch - live-verified vs ansible-core 2.19 on a Rocky 9 container).
#
# dnf/rpm are not on the spec host; everything runs against shimmed
# binaries on PATH via the plugin's _environment (same method as the
# issue-1019 tests) - no process-wide ENV mutation, so no serial!.
# The probe this pins is `yum update <options> --assumeno <names>`: a
# batch with an available upgrade aborts at the confirmation prompt
# (rc 1, "Operation aborted.", nothing upgraded), an already-latest
# batch exits 0 (both live-verified vs dnf4 on Rocky 9).
private def with_yum1098_shims(update_mode : String, &)
  bin_dir = File.join(Dir.tempdir, "krikri-yum1098-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(bin_dir)

  rpm_shim = <<-'SH'
    #!/bin/sh
    if [ "$2" = "--whatprovides" ]; then
      exit 1
    fi
    qarg="$4"
    [ -n "$qarg" ] || qarg="$2"
    for pair in ${KRIKRI_RPM_INSTALLED:-}; do
      pkg="${pair%%=*}"; nevra="${pair#*=}"
      [ "$qarg" = "$pkg" ] && { printf '%s\n' "$nevra"; exit 0; }
    done
    exit 1
    SH

  pkg_shim = <<-SH
    #!/bin/sh
    if [ "$1" = "update" ]; then
      case "${KRIKRI_YUM_UPDATE:-noop}" in
      update-available)
        echo "Operation aborted." >&2
        exit 1
        ;;
      metadata-failure)
        echo "Errors during downloading metadata for repository 'badrepo':" >&2
        echo "  - Curl error (37): Couldn't read a file:// file for file:///nonexistent/repo/repodata/repomd.xml" >&2
        echo "Error: Failed to download metadata for repo 'badrepo': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried" >&2
        exit 1
        ;;
      esac
    fi
    echo "Nothing to do"
    exit 0
    SH

  File.write(File.join(bin_dir, "rpm"), rpm_shim)
  File.write(File.join(bin_dir, "dnf"), pkg_shim)
  File.write(File.join(bin_dir, "yum"), pkg_shim)
  {"rpm", "dnf", "yum"}.each { |bin| File.chmod(File.join(bin_dir, bin), 0o755) }

  env = {
    "PATH"                 => "#{bin_dir}:/usr/bin:/bin",
    "KRIKRI_RPM_INSTALLED" => "bind=bind-9.16.23-24.el9.x86_64 bind-utils=bind-utils-9.16.23-24.el9.x86_64",
    "KRIKRI_YUM_UPDATE"    => update_mode,
  }.to_json
  yield env
ensure
  FileUtils.rm_rf(bin_dir) if bin_dir
end

describe "yum/dnf update-shaped check mode - an already-latest batch is the no-op ok (issue 1098)" do
  it "check mode on an installed-and-latest batch reports ok, not changed" do
    with_yum1098_shims("noop") do |env|
      result = PluginSpecHelper.run("yum", {
        "name"                => "[\"bind\", \"bind-utils\"]",
        "state"               => "latest",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(0)
    end
  end

  it "check mode still reports changed when an upgrade is actually available" do
    with_yum1098_shims("update-available") do |env|
      result = PluginSpecHelper.run("yum", {
        "name"                => "[\"bind\", \"bind-utils\"]",
        "state"               => "latest",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
    end
  end

  it "check mode fails with the metadata-failure shape when repo metadata cannot download" do
    with_yum1098_shims("metadata-failure") do |env|
      result = PluginSpecHelper.run("yum", {
        "name"                => "[\"bind\", \"bind-utils\"]",
        "state"               => "latest",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(
        "Failed to download metadata for repo 'badrepo': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried")
    end
  end

  it "update_only with state present reports ok for an already-latest batch under --check" do
    with_yum1098_shims("noop") do |env|
      result = PluginSpecHelper.run("yum", {
        "name"                => "[\"bind\"]",
        "state"               => "present",
        "update_only"         => "true",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
    end
  end
end
