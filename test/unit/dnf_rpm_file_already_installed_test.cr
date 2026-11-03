require "../minitest_helper"
require "file_utils"
require "json"

# Issue #781: `dnf: name: <rpm-url>` with the rpm ALREADY installed used to
# report changed under --check where real ansible reported ok. Real's dnf.py
# hands every URL/file name to base.package_install, and dnf resolves an
# install of an identical already-installed NEVRA to an EMPTY transaction -
# msg "Nothing to do", changed: false, rc 0 - in check mode exactly as in a
# real run. This engine classified every URL/file name as "would install",
# so check mode said changed. The rpm file's NEVRA has to come from its own
# header (rpm -qp): plain `rpm -q <path>` answers from the file header too
# (rc 0 whether installed or not), so it cannot tell "installed" apart.
#
# Live-verified vs ansible-core 2.19.11 on a Rocky 9 container (the issue's
# repro, tree served over http://127.0.0.1:8000):
#   present, already installed, --check -> ok: {"changed": false,
#       "msg": "Nothing to do", "rc": 0, "results": ["Installed <fetched
#       temp path>"]} - the temp path is fetch_file's random moduletmp name,
#       not reproducible; this engine reports the empty no-op results []
#       shape every other no-op uses.
#   present, already installed, real run -> same shape, ok.
#   present, not installed, --check -> changed with results
#       ["Installed: <nevra>"] (real also lists the fetched temp path).
#
# dnf/rpm are not on the spec host; everything runs against shimmed
# binaries on PATH via the plugin's _environment (same method as the
# issue-753 tests) - no process-wide ENV mutation, so no serial!.
private def with_dnf781_shims(installed : Bool, &)
  bin_dir = File.join(Dir.tempdir, "krikri-dnf781-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(bin_dir)

  rpm_shim = <<-'SH'
    #!/bin/sh
    if [ "$1" = "-qp" ]; then
      [ -f "$4" ] || exit 1
      printf '%s\n' "${KRIKRI_RPM_FILE_NEVRA:-}"
      exit 0
    fi
    if [ "$2" = "--whatprovides" ]; then
      exit 1
    fi
    qarg="$4"
    [ -n "$qarg" ] || qarg="$2"
    if [ -f "$qarg" ]; then
      printf '%s\n' "${KRIKRI_RPM_FILE_NEVRA:-}"
      exit 0
    fi
    for pair in ${KRIKRI_RPM_INSTALLED:-}; do
      pkg="${pair%%=*}"; nevra="${pair#*=}"
      [ "$qarg" = "$pkg" ] && { printf '%s\n' "$nevra"; exit 0; }
    done
    exit 1
    SH

  dnf_shim = <<-SH
    #!/bin/sh
    case "$2/$3" in
      "list/--available")
        exit 1
        ;;
    esac
    echo "Nothing to do"
    exit 0
    SH

  File.write(File.join(bin_dir, "rpm"), rpm_shim)
  File.write(File.join(bin_dir, "dnf"), dnf_shim)
  File.write(File.join(bin_dir, "yum"), dnf_shim)
  {"rpm", "dnf", "yum"}.each { |bin| File.chmod(File.join(bin_dir, bin), 0o755) }

  env = {
    "PATH"                  => "#{bin_dir}:/usr/bin:/bin",
    "KRIKRI_RPM_FILE_NEVRA" => "tree-1.8.0-10.el9.x86_64",
    "KRIKRI_RPM_INSTALLED"  => installed ? "tree-1.8.0-10.el9.x86_64=tree-1.8.0-10.el9.x86_64" : "",
  }.to_json
  yield env
ensure
  FileUtils.rm_rf(bin_dir) if bin_dir
end

describe "dnf plugin - rpm file already installed resolves to the no-op (issue 781)" do
  it "check mode on an already-installed rpm file reports Nothing to do, not changed" do
    with_dnf781_shims(true) do |env|
      rpm = PluginSpecHelper.tmp_path("tree-1.8.0-10.el9.x86_64.rpm")
      File.write(rpm, "not a real rpm - the shims never parse it")
      result = PluginSpecHelper.run("dnf", {
        "name"                => rpm,
        "state"               => "present",
        "disable_gpg_check"   => "true",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })
      result["changed"].as_bool.must_equal(false)
      result["failed"]?.try(&.as_bool?).must_be_nil
      result["msg"].as_s.must_equal("Nothing to do")
      result["rc"].as_i.must_equal(0)
      result["results"].as_a.must_equal([] of JSON::Any)
    end
  end

  it "check mode on an rpm file whose NEVRA is not installed still reports the would-install shape" do
    with_dnf781_shims(false) do |env|
      rpm = PluginSpecHelper.tmp_path("tree-1.8.0-10.el9.x86_64.rpm")
      File.write(rpm, "not a real rpm - the shims never parse it")
      result = PluginSpecHelper.run("dnf", {
        "name"                => rpm,
        "state"               => "present",
        "disable_gpg_check"   => "true",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Installed: tree-1.8.0-10.el9.x86_64"])
    end
  end

  it "a real run on an already-installed rpm file is a no-op" do
    with_dnf781_shims(true) do |env|
      rpm = PluginSpecHelper.tmp_path("tree-1.8.0-10.el9.x86_64.rpm")
      File.write(rpm, "not a real rpm - the shims never parse it")
      result = PluginSpecHelper.run("dnf", {
        "name"              => rpm,
        "state"             => "present",
        "disable_gpg_check" => "true",
        "_environment"      => env,
      })
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
    end
  end

  it "latest on an already-installed rpm file is a no-op" do
    with_dnf781_shims(true) do |env|
      rpm = PluginSpecHelper.tmp_path("tree-1.8.0-10.el9.x86_64.rpm")
      File.write(rpm, "not a real rpm - the shims never parse it")
      result = PluginSpecHelper.run("dnf", {
        "name"                => rpm,
        "state"               => "latest",
        "disable_gpg_check"   => "true",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
    end
  end
end
