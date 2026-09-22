require "../spec_helper"
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

# Builds a real minimal .deb (real dpkg-deb control metadata, so the
# plugin's `dpkg-deb -f` read is genuinely executed, not shape-matched)
# plus a PATH shim dir: `curl` stages the fixture onto its -o target
# (standing in for the network, optionally failing with a caller-chosen
# exit code) and logs every invocation; `apt-get` logs and exits 0 (the
# unprivileged spec process cannot really install). Real /usr/bin
# binaries stay reachable behind the shim dir, so `dpkg-deb -f` and the
# not-installed `dpkg -l` probe run for real against the fixture.
# dpkg_installed_line, when given, adds a `dpkg -l` shim reporting that
# exact installed-status line so the idempotency short-circuit can be
# exercised without a real system mutation. Yields the `_environment`
# JSON param, the fixture path, the curl call log and the apt-get call
# log.
private def with_deb_fixture_shims(curl_exit : Int32 = 0, dpkg_installed_line : String? = nil, &)
  dir = File.join(Dir.tempdir, "krikri-apt-deb-#{Random.rand(1_000_000)}")
  shims = File.join(dir, "shims")
  FileUtils.mkdir_p(File.join(dir, "pkg", "DEBIAN"))
  FileUtils.mkdir_p(shims)
  fixture = File.join(dir, "krikri-spec-deb_1.0_all.deb")
  curl_log = File.join(dir, "curl.log")
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
  File.write(File.join(shims, "apt-get"), <<-SHIM)
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    exit 0
    SHIM
  if line = dpkg_installed_line
    File.write(File.join(shims, "dpkg"), <<-SHIM)
      #!/bin/sh
      if [ "$1" = "-l" ]; then
        echo "#{line}"
        exit 0
      fi
      exec /usr/bin/dpkg "$@"
      SHIM
  end
  File.chmod(File.join(shims, "curl"), 0o755)
  File.chmod(File.join(shims, "apt-get"), 0o755)
  File.chmod(File.join(shims, "dpkg"), 0o755) if dpkg_installed_line

  env = {
    "PATH"                => "#{shims}:/usr/bin:/bin",
    "KRIKRI_DEB_FIXTURE"  => fixture,
    "KRIKRI_DEB_CURL_LOG" => curl_log,
    "KRIKRI_APT_CALLS"    => apt_log,
    "KRIKRI_CURL_EXIT"    => curl_exit.to_s,
  }.to_json
  yield env, fixture, curl_log, apt_log
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "apt plugin deb: URL download-then-install" do
  it "downloads a deb: URL first and installs the downloaded temp path" do
    with_deb_fixture_shims do |env, fixture, curl_log, apt_log|
      url = "https://packages.example.invalid/krikri-spec-deb_1.0_all.deb"
      result = PluginSpecHelper.run("apt", {
        "deb"               => url,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true
      result["msg"].as_s.should eq("Installed krikri-spec-deb")

      # The download step ran, against the URL.
      curl_calls = File.exists?(curl_log) ? File.read_lines(curl_log) : [] of String
      curl_calls.size.should eq(1)
      curl_calls.first.should contain(url)

      # The install consumed a private /tmp staging file, not the URL -
      # and one that still existed when dpkg-deb -f read it (the old
      # ensure-scoped delete removed it before that read, which is the
      # exact regression here). Real dpkg-deb -f succeeded above (the
      # fixture's Package: krikri-spec-deb metadata drove the msg).
      install_calls = File.exists?(apt_log) ? File.read_lines(apt_log) : [] of String
      install_calls.size.should eq(1)
      install_line = install_calls.first
      install_line.should contain("install")
      install_line.should_not contain(url)
      temp_path = install_line.split(" ").last
      temp_path.starts_with?(File.join(Dir.tempdir, ".krikri-playbook-deb-")).should be_true
      # Command-line apt-get/dpkg refuse non-.deb files with "Unsupported
      # file ... given on commandline" (python-apt, which real Ansible
      # uses, never sees the filename, so only our own path was broken).
      temp_path.ends_with?(".deb").should be_true
      # Real Ansible's add_cleanup_file semantics: the temp is removed
      # at module exit, not before the install.
      File.exists?(temp_path).should be_false
    end
  end

  it "fails with the download error when the URL fetch fails" do
    with_deb_fixture_shims(curl_exit: 7) do |env, fixture, _, apt_log|
      url = "https://packages.example.invalid/krikri-spec-deb_1.0_all.deb"
      result = PluginSpecHelper.run("apt", {
        "deb"               => url,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("Failed to download #{url}")
      # Nothing reached dpkg.
      File.exists?(apt_log).should be_false
    end
  end

  it "installs a local-path deb: unchanged, with no download step" do
    with_deb_fixture_shims do |env, fixture, curl_log, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true
      result["msg"].as_s.should eq("Installed krikri-spec-deb")

      # No download for a local file: curl is never invoked, and the
      # install consumes the given path verbatim.
      File.exists?(curl_log).should be_false
      install_calls = File.exists?(apt_log) ? File.read_lines(apt_log) : [] of String
      install_calls.size.should eq(1)
      install_calls.first.should contain(fixture)
    end
  end

  it "skips the install when the deb's own name/version is already installed" do
    with_deb_fixture_shims(dpkg_installed_line: "ii  krikri-spec-deb  1.0  all  krikri apt deb spec fixture") do |env, fixture, _, apt_log|
      result = PluginSpecHelper.run("apt", {
        "deb"               => fixture,
        "state"             => "present",
        "_environment"      => env,
        "_policy_rc_d_path" => File.join(File.dirname(fixture), "policy-rc.d"),
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_false
      result["msg"].as_s.should eq("krikri-spec-deb already at version 1.0")
      File.exists?(apt_log).should be_false
    end
  end
end
