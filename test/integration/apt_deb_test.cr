require "../minitest_helper"
require "file_utils"

# Regression spec for `apt`'s `deb:` handling (round900223,
# j91321.sysmon's "(Ubuntu) Download and install Microsoft repository
# from deb package" task): a deb: URL must be downloaded to a temp file
# first and the DOWNLOADED path (never the raw URL string) handed to the
# dpkg metadata read and the install - and the downloaded temp must live
# until that whole install finished. The old code's ensure-scoped delete
# around just the download removed the file before the very next
# `dpkg-deb -f`, failing every URL deb: with "dpkg-deb: error: failed to
# read archive ... No such file or directory". Real Ansible's own apt
# module (apt.py's `if '://' in p['deb']: fetch_file(...)`) downloads to
# a module-tmpdir temp registered with add_cleanup_file, i.e. removed
# only at module exit. The local-path deb: case must be completely
# untouched: no download step at all.
#
# Result-value pins come from the real 2.19.11 podman-container oracle
# captures (apt_check_deb / apt_real_deb / apt_real_deb_again /
# apt_fail_deb_*): real install_deb runs `dpkg <options> -i <deb>`, its
# success exit is exit_json(changed=True, stdout=out, stderr=err,
# diff=parse_diff(out)) with NO diff-mode guard and NO msg, its
# already-installed exit is the bare (changed=False, stdout='',
# stderr='', diff='') with diff the EMPTY STRING, and its
# DebPackage-construction failures register "Unable to install package:
# <python-apt error>".

# Builds a real minimal .deb (real dpkg-deb control metadata, so the
# plugin's `dpkg-deb -f` read is genuinely executed, not shape-matched)
# plus a PATH shim dir: `curl` stages the fixture onto its -o target
# (standing in for the network, optionally failing with a caller-chosen
# exit code) and logs every invocation; `dpkg` logs every invocation and
# answers `-l <pkg>` with an optionally-installed status line while
# simulating a successful `-i` install; `apt-get` logs and exits 0 (the
# dependency-resolution fallback for debs dpkg cannot install alone).
# Real /usr/bin binaries stay reachable behind the shim dir, so
# `dpkg-deb -f` runs for real against the fixture. Yields the
# `_environment` JSON param, the fixture path, the curl call log, the
# dpkg call log and the apt-get call log.
private def with_deb_fixture_shims(curl_exit : Int32 = 0, dpkg_installed_line : String? = nil, dpkg_install_exit : Int32 = 0, &)
  dir = File.join(Dir.tempdir, "krikri-apt-deb-#{Random.rand(1_000_000)}")
  shims = File.join(dir, "shims")
  FileUtils.mkdir_p(File.join(dir, "pkg", "DEBIAN"))
  FileUtils.mkdir_p(shims)
  fixture = File.join(dir, "krikri-spec-deb_1.0_all.deb")
  curl_log = File.join(dir, "curl.log")
  dpkg_log = File.join(dir, "dpkg.log")
  apt_log = File.join(dir, "apt.log")

  File.write(File.join(dir, "pkg", "DEBIAN", "control"),
    "Package: krikri-spec-deb\nVersion: 1.0\nArchitecture: all\n" \
    "Maintainer: spec <spec@local>\nDescription: krikri apt deb spec fixture\n")
  build = Process.run("dpkg-deb", ["--build", "--root-owner-group", File.join(dir, "pkg"), fixture],
    output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
  raise "dpkg-deb --build failed for the spec fixture" unless build.success?

  File.write(File.join(shims, "curl"), <<-SHIM)
    #!/bin/sh
    echo "$@" >> "$KRIKRI_DEB_CURL_LOG"
    out=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-o" ]; then out="$a"; fi
      prev="$a"
    done
    if [ "$KRIKRI_CURL_EXIT" != "0" ]; then
      echo "curl: (7) Failed to connect to krikri-spec host" >&2
      exit "$KRIKRI_CURL_EXIT"
    fi
    cp "$KRIKRI_DEB_FIXTURE" "$out"
    exit 0
    SHIM
  File.write(File.join(shims, "dpkg"), <<-SHIM)
    #!/bin/sh
    echo "$@" >> "$KRIKRI_DPKG_CALLS"
    if [ "$1" = "-l" ]; then
      if [ -n "$KRIKRI_DPKG_INSTALLED_LINE" ]; then
        echo "$KRIKRI_DPKG_INSTALLED_LINE"
      fi
      exit 0
    fi
    echo "Selecting previously unselected package krikri-spec-deb."
    echo "(Reading database ... 1 files and directories currently installed.)"
    echo "Preparing to unpack .../krikri-spec-deb_1.0_all.deb ..."
    echo "Unpacking krikri-spec-deb (1.0) ..."
    echo "Setting up krikri-spec-deb (1.0) ..."
    exit "$KRIKRI_DPKG_INSTALL_EXIT"
    SHIM
  File.write(File.join(shims, "apt-get"), <<-SHIM)
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    exit 0
    SHIM
  File.chmod(File.join(shims, "curl"), 0o755)
  File.chmod(File.join(shims, "dpkg"), 0o755)
  File.chmod(File.join(shims, "apt-get"), 0o755)

  env = {
    "PATH"                       => "#{shims}:/usr/bin:/bin",
    "KRIKRI_DEB_FIXTURE"         => fixture,
    "KRIKRI_DEB_CURL_LOG"        => curl_log,
    "KRIKRI_DPKG_CALLS"          => dpkg_log,
    "KRIKRI_APT_CALLS"           => apt_log,
    "KRIKRI_CURL_EXIT"           => curl_exit.to_s,
    "KRIKRI_DPKG_INSTALL_EXIT"   => dpkg_install_exit.to_s,
    "KRIKRI_DPKG_INSTALLED_LINE" => dpkg_installed_line.to_s,
  }.to_json
  yield env, fixture, curl_log, dpkg_log, apt_log
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "apt plugin deb: URL download-then-install" do
  it "downloads a deb: URL first and installs the downloaded temp path via dpkg -i" do
    with_deb_fixture_shims do |env, fixture, curl_log, dpkg_log, apt_log|
      url = "https://packages.example.invalid/krikri-spec-deb_1.0_all.deb"
      result = PluginSpecHelper.run("apt", {
        "deb"               => url,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      # Real's deb exits carry NO msg key (the old "Installed ..." msg
      # was this engine's invention).
      result["msg"]?.must_be_nil
      result["stdout"].as_s.must_include("Setting up krikri-spec-deb (1.0)")
      # Real install_deb applies parse_diff with NO diff-mode guard.
      result["diff"].as_h["prepared"].as_s.must_include("Setting up")

      # The download step ran, against the URL.
      curl_calls = File.exists?(curl_log) ? File.read_lines(curl_log) : [] of String
      curl_calls.size.must_equal(1)
      curl_calls.first.must_include(url)

      # The install consumed a private /tmp staging file, not the URL -
      # and one that still existed when dpkg-deb -f read it (the old
      # ensure-scoped delete removed it before that read, which is the
      # exact regression here). Real dpkg-deb -f succeeded above (the
      # fixture's Package: krikri-spec-deb metadata drove the idempotency
      # probe), and the install itself went through real's
      # `dpkg <options> -i <deb>` shape.
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      install_calls = dpkg_calls.select(&.includes?(" -i "))
      install_calls.size.must_equal(1)
      install_line = install_calls.first
      install_line.must_include("--force-confdef --force-confold")
      install_line.wont_include(url)
      temp_path = install_line.split(" ").last
      temp_path.starts_with?(File.join(Dir.tempdir, ".krikri-playbook-deb-")).must_equal(true)
      # Command-line apt-get/dpkg refuse non-.deb files with "Unsupported
      # file ... given on commandline" (python-apt, which real Ansible
      # uses, never sees the filename, so only our own path was broken).
      temp_path.ends_with?(".deb").must_equal(true)
      # Real Ansible's add_cleanup_file semantics: the temp is removed
      # at module exit, not before the install.
      File.exists?(temp_path).must_equal(false)
      # The apt-get dependency fallback never ran for a dep-free deb.
      File.exists?(apt_log).must_equal(false)
    end
  end

  it "fails with the download error when the URL fetch fails" do
    with_deb_fixture_shims(curl_exit: 7) do |env, fixture, _, dpkg_log, apt_log|
      url = "https://packages.example.invalid/krikri-spec-deb_1.0_all.deb"
      result = PluginSpecHelper.run("apt", {
        "deb"               => url,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("Failed to download #{url}")
      # Nothing reached dpkg.
      File.exists?(dpkg_log).must_equal(false)
      File.exists?(apt_log).must_equal(false)
    end
  end

  it "installs a local-path deb: unchanged, with no download step" do
    with_deb_fixture_shims do |env, fixture, curl_log, dpkg_log, _apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["msg"]?.must_be_nil

      # No download for a local file: curl is never invoked, and the
      # install consumes the given path verbatim through dpkg -i.
      File.exists?(curl_log).must_equal(false)
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      install_calls = dpkg_calls.select(&.includes?(" -i "))
      install_calls.size.must_equal(1)
      install_calls.first.must_include(fixture)
    end
  end

  it "skips the install when the deb's own name/version is already installed" do
    with_deb_fixture_shims(dpkg_installed_line: "ii  krikri-spec-deb  1.0  all  krikri apt deb spec fixture") do |env, fixture, _, dpkg_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"]?.must_be_nil
      # Real's already-installed deb exit: empty stdout/stderr and diff
      # as the EMPTY STRING (retvals.get('diff', '')).
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("")
      result["diff"].as_s.must_equal("")
      # Only the metadata + idempotency probes ran - no install, no
      # apt-get fallback.
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.select(&.includes?(" -i ")).empty?.must_equal(true)
      File.exists?(apt_log).must_equal(false)
    end
  end

  it "falls back to apt-get install when dpkg -i cannot resolve the deb's dependencies" do
    with_deb_fixture_shims(dpkg_install_exit: 1) do |env, fixture, _, dpkg_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      # dpkg -i ran and failed first; apt-get then resolved the install.
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.count(&.includes?(" -i ")).must_equal(1)
      apt_calls = File.exists?(apt_log) ? File.read_lines(apt_log) : [] of String
      apt_calls.size.must_equal(1)
      apt_calls.first.must_include("install")
      apt_calls.first.must_include(fixture)
    end
  end

  it "registers real's DebPackage-construction failure wording for a missing deb file" do
    result = PluginSpecHelper.run("apt", {
      "deb"   => "/tmp/krikri-spec-nosuch.deb",
      "state" => "present",
    })

    result["failed"].as_bool.must_equal(true)
    # python-apt's own open() error text, via real's
    # "Unable to install package: <e>" fail_json.
    result["msg"].as_s.must_equal("Unable to install package: E:Could not open file /tmp/krikri-spec-nosuch.deb - open (2: No such file or directory)")
  end

  it "registers real's DebPackage-construction failure wording for a non-archive file" do
    dir = File.join(Dir.tempdir, "krikri-apt-deb-bad-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(dir)
    begin
      bad = File.join(dir, "not-a-deb.deb")
      File.write(bad, "this is not a deb\n")
      result = PluginSpecHelper.run("apt", {
        "deb"   => bad,
        "state" => "present",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Unable to install package: E:Invalid archive signature")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
