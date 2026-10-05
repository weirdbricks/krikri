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
# read archive ... No such file or directory". Ansible's own apt
# module (apt.py's `if '://' in p['deb']: fetch_file(...)`) downloads to
# a module-tmpdir temp registered with add_cleanup_file, i.e. removed
# only at module exit. The local-path deb: case must be completely
# untouched: no download step at all.
#
# Result-value pins come from the Ansible 2.19.11 podman-container oracle
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
# exit code) and logs every invocation; `dpkg` logs every invocation,
# answers `-l <pkg>` with an optionally-installed status line, delegates
# `--compare-versions` to the real /usr/bin/dpkg (Debian-version
# ordering is not reimplemented in a shell shim) and simulates a
# successful `-i` install; `dpkg-query` answers with an optional
# pre-set status-line set (driving the dependency resolver's installed
# status probe); `apt-cache` answers `policy <name>` with a
# "Candidate: 1.0" line for a configurable name list (nothing for any
# other name = an unknown name), "Candidate: (none)" for a configurable
# purely-virtual name list, and `showpkg <name>` with a Reverse Provides
# list ("name:provider1,provider2" entries) for the provider walks; `apt-get` logs, prints optional
# stdout/stderr and exits with a configurable code. Real /usr/bin
# binaries stay reachable behind the shim dir, so `dpkg-deb -f` runs
# for real against the fixture. Yields the `_environment` JSON param,
# the fixture path, the curl call log, the dpkg call log and the
# apt-get call log.
private def with_deb_fixture_shims(curl_exit : Int32 = 0, dpkg_installed_line : String? = nil, dpkg_install_exit : Int32 = 0,
                                   depends : String? = nil, recommends : String? = nil,
                                   dpkg_query_lines : String? = nil, apt_candidate_names : String? = nil,
                                   apt_virtual_names : String? = nil, apt_provides : String? = nil,
                                   apt_get_exit : Int32 = 0, apt_get_stdout : String = "", apt_get_stderr : String = "", &)
  dir = File.join(Dir.tempdir, "krikri-apt-deb-#{Random.rand(1_000_000)}")
  shims = File.join(dir, "shims")
  FileUtils.mkdir_p(File.join(dir, "pkg", "DEBIAN"))
  FileUtils.mkdir_p(shims)
  fixture = File.join(dir, "krikri-spec-deb_1.0_all.deb")
  curl_log = File.join(dir, "curl.log")
  dpkg_log = File.join(dir, "dpkg.log")
  apt_log = File.join(dir, "apt.log")

  control = "Package: krikri-spec-deb\nVersion: 1.0\nArchitecture: all\n" \
            "Maintainer: spec <spec@local>\nDescription: krikri apt deb spec fixture\n"
  control += "Depends: #{depends}\n" if depends
  control += "Recommends: #{recommends}\n" if recommends
  File.write(File.join(dir, "pkg", "DEBIAN", "control"), control)
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
    if [ "$1" = "--compare-versions" ]; then
      exec /usr/bin/dpkg "$@"
    fi
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
  File.write(File.join(shims, "dpkg-query"), <<-SHIM)
    #!/bin/sh
    if [ -n "$KRIKRI_DPKG_QUERY_LINES" ]; then
      printf '%s\n' "$KRIKRI_DPKG_QUERY_LINES"
    fi
    exit 0
    SHIM
  File.write(File.join(shims, "apt-cache"), <<-SHIM)
    #!/bin/sh
    if [ "$1" = "showpkg" ]; then
      for n in $KRIKRI_APT_PROVIDES; do
        name="${n%%:*}"
        if [ "$name" = "$2" ]; then
          echo "Reverse Provides: "
          rest="${n#*:}"
          oldIFS="$IFS"; IFS=","
          for p in $rest; do echo "$p"; done
          IFS="$oldIFS"
        fi
      done
      exit 0
    fi
    for n in $KRIKRI_APT_VIRTUAL_NAMES; do
      if [ "$n" = "$2" ]; then
        echo "Candidate: (none)"
      fi
    done
    for n in $KRIKRI_APT_CANDIDATE_NAMES; do
      if [ "$n" = "$2" ]; then
        echo "Candidate: 1.0"
      fi
    done
    exit 0
    SHIM
  File.write(File.join(shims, "apt-get"), <<-SHIM)
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    if [ -n "$KRIKRI_APT_GET_STDOUT" ]; then
      printf '%s\n' "$KRIKRI_APT_GET_STDOUT"
    fi
    if [ -n "$KRIKRI_APT_GET_STDERR" ]; then
      printf '%s\n' "$KRIKRI_APT_GET_STDERR" >&2
    fi
    exit "$KRIKRI_APT_GET_EXIT"
    SHIM
  File.chmod(File.join(shims, "curl"), 0o755)
  File.chmod(File.join(shims, "dpkg"), 0o755)
  File.chmod(File.join(shims, "dpkg-query"), 0o755)
  File.chmod(File.join(shims, "apt-cache"), 0o755)
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
    "KRIKRI_DPKG_QUERY_LINES"    => dpkg_query_lines.to_s,
    "KRIKRI_APT_CANDIDATE_NAMES" => apt_candidate_names.to_s,
    "KRIKRI_APT_VIRTUAL_NAMES"   => apt_virtual_names.to_s,
    "KRIKRI_APT_PROVIDES"        => apt_provides.to_s,
    "KRIKRI_APT_GET_EXIT"        => apt_get_exit.to_s,
    "KRIKRI_APT_GET_STDOUT"      => apt_get_stdout,
    "KRIKRI_APT_GET_STDERR"      => apt_get_stderr,
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
      # Ansible's deb exits carry NO msg key (the old "Installed ..." msg
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
      # probe), and the install itself went through Ansible's
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
      # file ... given on commandline" (python-apt, which Ansible
      # uses, never sees the filename, so only our own path was broken).
      temp_path.ends_with?(".deb").must_equal(true)
      # Ansible's add_cleanup_file semantics: the temp is removed
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
      # Ansible's already-installed deb exit: empty stdout/stderr and diff
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

  it "registers Ansible's dpkg failure shape when a dep-free deb's dpkg -i fails (no apt-get fallback)" do
    # Real install_deb never falls back to `apt-get install <deb>`: the
    # dependency pre-install goes through install() BEFORE the dpkg run,
    # so a deb with no dependency fields whose dpkg -i fails (e.g. a
    # failing preinst script) fails with the dpkg failure shape directly.
    with_deb_fixture_shims(dpkg_install_exit: 1) do |env, fixture, _, dpkg_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("dpkg --force-confdef --force-confold -i #{fixture} failed")
      # dpkg -i ran exactly once and apt-get never ran - the dependency
      # pre-install has nothing to do when the deb declares no Depends.
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.count(&.includes?(" -i ")).must_equal(1)
      File.exists?(apt_log).must_equal(false)
    end
  end

  it "registers Ansible's DebPackage-construction failure wording for a missing deb file" do
    result = PluginSpecHelper.run("apt", {
      "deb"   => "/tmp/krikri-spec-nosuch.deb",
      "state" => "present",
    })

    result["failed"].as_bool.must_equal(true)
    # python-apt's own open() error text, via Ansible's
    # "Unable to install package: <e>" fail_json.
    result["msg"].as_s.must_equal("Unable to install package: E:Could not open file /tmp/krikri-spec-nosuch.deb - open (2: No such file or directory)")
  end

  it "registers Ansible's DebPackage-construction failure wording for a non-archive file" do
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

# Regression spec for the round-1200xxx divergence (appsilon.r_language,
# JonasPammer/kso512.checkmk_server, Oefenweb.rstudio_server): real
# install_deb resolves the .deb's own Depends/Pre-Depends FIRST -
# missing dependencies go through install()'s apt-get machinery - and
# only then runs `dpkg <options> -i`. A bare dpkg -i cannot resolve
# dependencies and dies with "dependency problems prevent
# configuration", which is exactly what the old engine registered (the
# real roles' missing deps: libbz2-dev/traceroute/libssl-dev et al).
# The old `apt-get install <deb>` dpkg-failure fallback is gone - real
# install_deb has no such second chance.
describe "apt plugin deb: dependency pre-install" do
  it "pre-installs the deb's missing dependencies via apt-get, then runs dpkg -i" do
    with_deb_fixture_shims(depends: "dep-a, dep-b",
      dpkg_query_lines: "", apt_candidate_names: "dep-a dep-b",
      apt_get_stdout: "Setting up dep-a (1.0) ...") do |env, fixture, _, dpkg_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["msg"]?.must_be_nil

      # One apt-get install for BOTH missing deps in one shot, each spec
      # carrying install()'s resolved-candidate pin, before dpkg runs.
      apt_calls = File.exists?(apt_log) ? File.read_lines(apt_log) : [] of String
      apt_calls.size.must_equal(1)
      apt_calls.first.must_include("install")
      apt_calls.first.must_include("dep-a=1.0")
      apt_calls.first.must_include("dep-b=1.0")
      apt_calls.first.wont_include(fixture)

      # dpkg -i ran once, AFTER the deps install.
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.count(&.includes?(" -i ")).must_equal(1)

      # install_deb's merge: deps stdout first, dpkg stdout after.
      stdout = result["stdout"].as_s
      deps_idx = stdout.index("Setting up dep-a (1.0) ...")
      deb_idx = stdout.index("Setting up krikri-spec-deb (1.0)")
      flunk("expected deps output before dpkg output") unless deps_idx && deb_idx && deps_idx < deb_idx

      # retvals carried a diff with diff mode off -> the bare {} stays,
      # parse_diff of the dpkg output does NOT replace it here.
      result["diff"].as_h.size.must_equal(0)
    end
  end

  it "satisfies a versioned dependency from the already-installed package without touching apt-get" do
    with_deb_fixture_shims(depends: "dep-a (>= 1.0)",
      dpkg_query_lines: "ii 1.0 dep-a") do |env, fixture, _, dpkg_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["stdout"].as_s.must_include("Setting up krikri-spec-deb (1.0)")
      File.exists?(apt_log).must_equal(false)
      # The satisfaction decision went through dpkg's own version ordering.
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.any?(&.includes?("--compare-versions")).must_equal(true)
      dpkg_calls.count(&.includes?(" -i ")).must_equal(1)
    end
  end

  it "picks the first installable alternative of an or-group dependency" do
    with_deb_fixture_shims(depends: "dep-a | dep-b",
      apt_candidate_names: "dep-a dep-b") do |env, fixture, _, _, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      apt_calls = File.exists?(apt_log) ? File.read_lines(apt_log) : [] of String
      apt_calls.size.must_equal(1)
      apt_calls.first.must_include("dep-a=1.0")
      apt_calls.first.wont_include("dep-b")
    end
  end

  it "satisfies a purely virtual dependency through the installed provider (checkmk libffi8ubuntu1)" do
    # round-1300024/1300039 checkmk_server: jammy's check-mk-raw Depends:
    # "libffi8ubuntu1" is purely virtual on the archive (only libffi8
    # (= 3.4.2-4) exists, Provides: libffi8ubuntu1) and libffi8 is
    # already installed on the base image. python-apt's
    # _is_or_group_satisfied answers satisfied through the installed
    # provider; the old engine (which only consulted installed names and
    # apt candidates) failed "Dependency is not satisfiable:
    # libffi8ubuntu1" while real ansible succeeded on the same host.
    with_deb_fixture_shims(depends: "libffi8ubuntu1",
      dpkg_query_lines: "ii 3.4.2-4 libffi8",
      apt_virtual_names: "libffi8ubuntu1",
      apt_provides: "libffi8ubuntu1:libffi8") do |env, fixture, _, dpkg_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["msg"]?.must_be_nil
      # The group is satisfied by the installed provider, so NOTHING is
      # pre-installed and the dpkg -i run goes straight through.
      File.exists?(apt_log).must_equal(false)
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.count(&.includes?(" -i ")).must_equal(1)
    end
  end

  it "installs a purely virtual dependency's single provider when nothing provides it yet" do
    # _satisfy_or_group's provider path: a purely-virtual name with
    # EXACTLY ONE provider installs that provider (python-apt's "just
    # pick that, like apt" rule), still through install()'s machinery.
    with_deb_fixture_shims(depends: "kra-virt-a",
      apt_virtual_names: "kra-virt-a",
      apt_provides: "kra-virt-a:kra-provider",
      apt_candidate_names: "kra-provider") do |env, fixture, _, dpkg_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      apt_calls = File.exists?(apt_log) ? File.read_lines(apt_log) : [] of String
      apt_calls.size.must_equal(1)
      apt_calls.first.must_include("kra-provider=1.0")
      apt_calls.first.wont_include("kra-virt-a")
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.count(&.includes?(" -i ")).must_equal(1)
    end
  end

  it "still fails with DebPackage's wording for a multi-provider virtual dependency nothing provides" do
    # python-apt's _satisfy_or_group skips a purely-virtual name with
    # MORE than one provider (no lone provider to auto-pick), so the
    # group fails check() with the same unsatisfiable wording.
    with_deb_fixture_shims(depends: "kra-virt-b",
      apt_virtual_names: "kra-virt-b",
      apt_provides: "kra-virt-b:kra-provider-1,kra-provider-2") do |env, fixture, _, dpkg_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Dependency is not satisfiable: kra-virt-b\n")
      File.exists?(apt_log).must_equal(false)
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.select(&.includes?(" -i ")).empty?.must_equal(true)
    end
  end

  it "fails with DebPackage's unsatisfiable-dependency wording before any install runs" do
    with_deb_fixture_shims(depends: "dep-x (>= 2.0)") do |env, fixture, _, dpkg_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"].as_bool.must_equal(true)
      # python-apt's gettext string, trailing "\n" included; no
      # alternative has an apt candidate, so the group is unsatisfiable.
      result["msg"].as_s.must_equal("Dependency is not satisfiable: dep-x (>= 2.0)\n")
      File.exists?(apt_log).must_equal(false)
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.select(&.includes?(" -i ")).empty?.must_equal(true)
    end
  end

  it "re-fails install()'s retvals when the dependency apt-get install fails" do
    with_deb_fixture_shims(depends: "dep-a",
      apt_candidate_names: "dep-a",
      apt_get_exit: 100, apt_get_stderr: "E: Unable to locate package dep-a") do |env, fixture, _, dpkg_log, _|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"].as_bool.must_equal(true)
      # install()'s own failure msg shape, re-failed by install_deb
      # (apt-get resolves through PATH, so the binary in the quoted cmd
      # is the shim's absolute path).
      result["msg"].as_s.must_include("' failed: E: Unable to locate package dep-a")
      result["msg"].as_s.must_include("install 'dep-a=1.0'")
      result["rc"].as_i.must_equal(100)
      # The dpkg run never happened - the deps install short-circuits it.
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.select(&.includes?(" -i ")).empty?.must_equal(true)
    end
  end

  it "fails with DebPackage's later-version wording when the installed version is newer" do
    with_deb_fixture_shims(dpkg_installed_line: "ii  krikri-spec-deb  2.0  all  krikri apt deb spec fixture") do |env, fixture, _, dpkg_log, _|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("A later version is already installed")
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      dpkg_calls.select(&.includes?(" -i ")).empty?.must_equal(true)
    end
  end

  it "proceeds with the dpkg downgrade when force: releases the later-version gate" do
    with_deb_fixture_shims(dpkg_installed_line: "ii  krikri-spec-deb  2.0  all  krikri apt deb spec fixture") do |env, fixture, _, dpkg_log, _|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "force"             => "true",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      dpkg_calls = File.exists?(dpkg_log) ? File.read_lines(dpkg_log) : [] of String
      install_calls = dpkg_calls.select(&.includes?(" -i "))
      install_calls.size.must_equal(1)
      install_calls.first.must_include("--force-all")
    end
  end

  it "merges the deps and dpkg diffs through install_deb's prepared-append rule in diff mode" do
    with_deb_fixture_shims(depends: "dep-a",
      apt_candidate_names: "dep-a",
      apt_get_stdout: "Reading state information...\n1 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.\n") do |env, fixture, _, _, _|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_ansible_diff"     => "true",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      prepared = result["diff"].as_h["prepared"].as_s
      deps_idx = prepared.index("1 upgraded, 1 newly installed")
      deb_idx = prepared.index("Setting up krikri-spec-deb (1.0)")
      flunk("expected deps output before dpkg output") unless deps_idx && deb_idx && deps_idx < deb_idx
      # install_deb's own separator between the two prepared chunks.
      prepared.must_include("not upgraded.\n\nSelecting previously unselected package")
    end
  end
end
