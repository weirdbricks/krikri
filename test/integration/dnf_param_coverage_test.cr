require "../minitest_helper"
require "file_utils"
require "../../src/krikri/plugin_helpers/dnf_install_failures"

# Proactive parameter-coverage pass for the dnf/yum plugin family
# (src/krikri/plugin_helpers/rpm_package.cr's build_dnf_options).
#
# dnf/rpm are NOT installed on the spec host (Debian-based), so these
# specs pin the CLI-invocation SHAPE only: a fake `dnf`/`rpm` on PATH
# records the argv the plugin builds, and each example asserts the exact
# flag string for the params under test - "given these params, is the
# constructed command line correct" rather than "does dnf behave this
# way". Every expected flag was cross-checked against the locally
# installed ansible-core's own dnf.py module source
# not against
# a live dnf run - see the per-example comments for which claims come
# from that source vs. dnf's documented CLI surface (general dnf
# knowledge, not live-verified on this machine).

RECORDING_DNF = <<-'SH'
#!/bin/sh
# The repo-availability probe `package_installed?` runs before the
# whatprovides fallback (issue #280's fix) is not one of the install/
# transaction argvs these specs assert, so it answers silently instead
# of joining the recorded log - an empty KRIKRI_FAKE_DNF_AVAILABLE
# keeps its default answer (no such repo row), which leaves every
# existing example on the exact same fallback path it had before.
case "$*" in
  "-q list --available "*)
    [ -n "${KRIKRI_FAKE_DNF_AVAILABLE:-}" ] && exit 0
    exit 1
    ;;
esac
printf '%s\n' "$*" >> "${KRIKRI_FAKE_DNF_LOG:-/dev/null}"
echo "Installed:"
echo "  fake-pkg"
exit 0
SH

FAILING_RPM = "#!/bin/sh\nexit 1\n"

# Installs fake `dnf` (records its full argv, one invocation per line)
# and `rpm` (always "not installed", so every spec lands on the install
# path) at the front of PATH.
# The plugin child inherits this process's ENV, and the fake dnf's log
# path travels through it - ENV is process-global, so the whole block
# holds ENV_MUTEX under minitest's parallel workers.
private def with_recording_pkg_managers(&)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    bin_dir = File.tempname("krikri-fake-dnf")
    Dir.mkdir_p(bin_dir)
    dnf = File.join(bin_dir, "dnf")
    File.write(dnf, RECORDING_DNF)
    File.chmod(dnf, 0o755)
    rpm = File.join(bin_dir, "rpm")
    File.write(rpm, FAILING_RPM)
    File.chmod(rpm, 0o755)

    log = File.tempname("krikri-fake-dnv-log")
    previous_path = ENV["PATH"]?
    previous_log = ENV["KRIKRI_FAKE_DNF_LOG"]?
    ENV["PATH"] = "#{bin_dir}:#{ENV["PATH"]?}"
    ENV["KRIKRI_FAKE_DNF_LOG"] = log
    begin
      yield log
    ensure
      previous_path ? (ENV["PATH"] = previous_path) : ENV.delete("PATH")
      previous_log ? (ENV["KRIKRI_FAKE_DNF_LOG"] = previous_log) : ENV.delete("KRIKRI_FAKE_DNF_LOG")
      FileUtils.rm_r(bin_dir)
      File.delete(log) if File.exists?(log)
    end
  end
end

# The plugin's baseline option string with none of the new params set:
# -y (non-interactive), the localpkg_gpgcheck forcing from the earlier
# GPG-audit pass, and the historical unconditional `--best` (dnf's own
# built-in default; Ansible's best/nobest default is
# OS-distribution-dependent, so nothing better can be pinned without
# an OS-specific check).
BASELINE_OPTIONS = "-y --setopt=localpkg_gpgcheck=1 --best"

def recorded_install_command(log : String, invocations : Int32 = 1) : String
  lines = File.read_lines(log)
  lines.size.must_equal(invocations)
  lines[invocations - 1]
end

describe "dnf plugin - parameter coverage (CLI-invocation shape)" do
  it "builds the documented baseline when none of the new params are set" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {"name" => "fake-pkg", "state" => "present"})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal("install #{BASELINE_OPTIONS} fake-pkg")
    end
  end

  # dnf.py: `allowerasing` -> base.resolve(allow_erasing=self.allowerasing)
  # - dnf's own --allowerasing transaction flag.
  it "passes allowerasing: true through as --allowerasing" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"         => "fake-pkg",
        "state"        => "present",
        "allowerasing" => "true",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal("install #{BASELINE_OPTIONS} --allowerasing fake-pkg")
    end
  end

  # dnf.py _configure_base: `conf.best = not self.nobest` when nobest is
  # given, `conf.best = self.best` otherwise. There is no `best:` module
  # parameter in Ansible's yumdnf argument spec (only `nobest`) -
  # a `best:` mapping existed here briefly and was removed (Ansible
  # rejects it as an unsupported parameter); the nobest cases below cover
  # the mapping, and the argument-spec rejection spec covers the rest.

  it "maps nobest: true to --nobest (the inverted form of best:)" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"   => "fake-pkg",
        "state"  => "present",
        "nobest" => "true",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal("install -y --setopt=localpkg_gpgcheck=1 --nobest fake-pkg")
    end
  end

  it "maps nobest: false to --best" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"   => "fake-pkg",
        "state"  => "present",
        "nobest" => "false",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal("install #{BASELINE_OPTIONS} fake-pkg")
    end
  end

  # dnf.py _configure_base: `conf.cacheonly = True` - dnf's -C/--cacheonly.
  it "passes cacheonly: true through as --cacheonly" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"      => "fake-pkg",
        "state"     => "present",
        "cacheonly" => "true",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal("install #{BASELINE_OPTIONS} --cacheonly fake-pkg")
    end
  end

  # dnf.py _configure_base: `conf.config_file_path = conf_file` (after an
  # os.access readability check) - dnf's -c/--config.
  it "passes conf_file through as --config (single-quoted)" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"      => "fake-pkg",
        "state"     => "present",
        "conf_file" => "/etc/dnf/other.conf",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal("install #{BASELINE_OPTIONS} --config=/etc/dnf/other.conf fake-pkg")
    end
  end

  # dnf.py _configure_base: appends to conf.disable_excludes - dnf's
  # --disableexcludes=[all|main|repoid].
  it "passes disable_excludes through as --disableexcludes" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"             => "fake-pkg",
        "state"            => "present",
        "disable_excludes" => "main",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal("install #{BASELINE_OPTIONS} --disableexcludes=main fake-pkg")
    end
  end

  # dnf.py _base: `base.init_plugins(set(self.disable_plugin),
  # set(self.enable_plugin))` - dnf's --enableplugin/--disableplugin,
  # per-transaction only. List params can arrive as a JSON array string
  # (how the PluginManager serializes lists) or a comma-separated string
  # (Ansible's own listify_comma_sep_strings_in_list).
  it "expands enable_plugin/disable_plugin (JSON array form) to one flag per name" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"           => "fake-pkg",
        "state"          => "present",
        "enable_plugin"  => %(["versionlock", "supspeed"]),
        "disable_plugin" => %(["fastestmirror"]),
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal(
        "install #{BASELINE_OPTIONS} --enableplugin=versionlock --enableplugin=supspeed --disableplugin=fastestmirror fake-pkg")
    end
  end

  it "expands enable_plugin/disable_plugin (comma-separated form) to one flag per name" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"           => "fake-pkg",
        "state"          => "present",
        "enable_plugin"  => "versionlock,supspeed",
        "disable_plugin" => "fastestmirror",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal(
        "install #{BASELINE_OPTIONS} --enableplugin=versionlock --enableplugin=supspeed --disableplugin=fastestmirror fake-pkg")
    end
  end

  # dnf.py _configure_base: extends conf.exclude - dnf's --exclude.
  # Globs must reach dnf unexpanded, so they're shell-quoted.
  it "expands exclude (JSON array form) to one quoted --exclude per name" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"    => "fake-pkg",
        "state"   => "present",
        "exclude" => %(["kernel*", "vim*"]),
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal(
        "install #{BASELINE_OPTIONS} --exclude=kernel* --exclude=vim* fake-pkg")
    end
  end

  it "expands exclude (comma-separated string form) to one quoted --exclude per name" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"    => "fake-pkg",
        "state"   => "present",
        "exclude" => "kernel*, vim*",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal(
        "install #{BASELINE_OPTIONS} --exclude=kernel* --exclude=vim* fake-pkg")
    end
  end

  # dnf.py _configure_base: `conf.installroot = installroot` - dnf's
  # --installroot. "/" is dnf's own default, so it isn't emitted.
  it "passes installroot through as --installroot and omits the default /" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"        => "fake-pkg",
        "state"       => "present",
        "installroot" => "/mnt/sysimage",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal(
        "install #{BASELINE_OPTIONS} --installroot=/mnt/sysimage fake-pkg")

      result2 = PluginSpecHelper.run("dnf", {
        "name"        => "fake-pkg",
        "state"       => "present",
        "installroot" => "/",
      })
      falsey?(result2["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log, 2).must_equal("install #{BASELINE_OPTIONS} fake-pkg")
    end
  end

  # dnf.py _configure_base: `conf.substitutions['releasever'] =
  # self.releasever` - dnf's --releasever.
  it "passes releasever through as --releasever" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"       => "fake-pkg",
        "state"      => "present",
        "releasever" => "9",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal(
        "install #{BASELINE_OPTIONS} --releasever=9 fake-pkg")
    end
  end

  # dnf.py _configure_base: `conf.sslverify = sslverify` (default true).
  # dnf's CLI surface for the conf option is --setopt=sslverify=...
  it "maps sslverify: false to --setopt=sslverify=False and leaves the default silent" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"      => "fake-pkg",
        "state"     => "present",
        "sslverify" => "false",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal(
        "install -y --setopt=localpkg_gpgcheck=1 --best --setopt=sslverify=False fake-pkg")
    end
  end

  # dnf.py _configure_base: `conf.downloadonly = True` and, only when
  # download_only is set, `conf.destdir = download_dir` - dnf's
  # --downloadonly / --downloaddir.
  it "maps download_only: true to --downloadonly and adds --downloaddir only alongside it" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"          => "fake-pkg",
        "state"         => "present",
        "download_only" => "true",
        "download_dir"  => "/tmp/rpms",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal(
        "install #{BASELINE_OPTIONS} --downloadonly --downloaddir=/tmp/rpms fake-pkg")

      # download_dir without download_only has no effect - exactly as in
      # Ansible (conf.destdir is only set when download_only is set).
      result2 = PluginSpecHelper.run("dnf", {
        "name"         => "fake-pkg",
        "state"        => "present",
        "download_dir" => "/tmp/rpms",
      })
      falsey?(result2["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log, 2).must_equal("install #{BASELINE_OPTIONS} fake-pkg")
    end
  end

  # install_repoquery / validate_certs / lock_timeout are accepted
  # no-ops for the dnf backend, matching ansible-core's own dnf.py:
  # - install_repoquery is documented as "effectively a no-op in DNF"
  #   (deprecated, removal slated for ansible-core 2.20);
  # - validate_certs only applies controller-side when Ansible
  #   fetches an https RPM URL itself (fetch_file in dnf.py's
  #   _parse_spec_group_file); krikri installs URL rpms on-target via
  #   dnf itself, so there is no controller fetch to validate;
  # - lock_timeout is read in the shared yumdnf base but never
  #   referenced anywhere in dnf.py's implementation (the dnf python
  #   API waits on its own lock internally; only the retired yum
  #   backend consumed it).
  it "accepts install_repoquery/validate_certs/lock_timeout as documented no-ops" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"              => "fake-pkg",
        "state"             => "present",
        "install_repoquery" => "false",
        "validate_certs"    => "false",
        "lock_timeout"      => "90",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal("install #{BASELINE_OPTIONS} fake-pkg")
    end
  end

  # dnf.py's argument spec: use_backend choices are
  # ['auto', 'dnf', 'yum', 'yum4', 'dnf4', 'dnf5'] and Ansible
  # fails anything else with the standard choices-validation message
  # before module code runs. Valid choices are accepted, then no-op:
  # krikri has a single dnf implementation to route to.
  it "validates use_backend against Ansible's choice list" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"        => "fake-pkg",
        "state"       => "present",
        "use_backend" => "dnf5",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      recorded_install_command(log).must_equal("install #{BASELINE_OPTIONS} fake-pkg")

      bad = PluginSpecHelper.run("dnf", {
        "name"        => "fake-pkg",
        "state"       => "present",
        "use_backend" => "portage",
      })
      bad["failed"].as_bool.must_equal(true)
      bad["msg"].as_s.must_equal(
        "value of use_backend must be one of: auto, dnf, yum, yum4, dnf4, dnf5, got: portage")
      File.read_lines(log).size.must_equal(1)
    end
  end
end

# Issue #280 (Rocky 9, zorlin.rust, round round29879595): `dnf: name:
# [curl, gcc], state: present` on a host with curl-minimal installed -
# curl-minimal Provides: the "curl" capability - must still reach the
# install batch. Real ansible resolves `curl` to the repo package of
# that exact name and fails the task with dnf's own Depsolve Error
# (curl conflicts with curl-minimal; rc 1, failures/results []), while
# the whatprovides fallback in package_installed? classified curl as
# already installed and the task reported ok/changed, installing only
# gcc. Verified live: `dnf -q list --available curl` exits 0 there,
# `dnf -q list --available php-json` (a purely virtual name with no
# repo row of its own) exits 1. dnf/rpm are not on the spec host, so a
# dispatching fake rpm/dnf builds the Rocky resolution table by hand:
# plain `rpm -q` never matches, the whatprovides lookup matches what
# KRIKRI_FAKE_RPM_PROVIDES lists, the availability probe matches what
# KRIKRI_FAKE_DNF_AVAILABLE lists, and KRIKRI_FAKE_DNF_DEPSOLVE turns
# the install invocation into the depsolve failure real dnf printed.
private ISSUE280_PROBLEM_BLOCK = [
  " Problem: problem with installed package curl-minimal-7.76.1-26.el9_3.2.0.1.x86_64",
  "  - package curl-minimal-7.76.1-40.el9.x86_64 from baseos conflicts with curl provided by curl-7.76.1-40.el9_8.8.x86_64 from baseos",
  "  - cannot install the best candidate for the job",
].join("\n")

# What the real dnf CLI printed to stderr on that host's `dnf install
# curl` attempt - the Problem block inside the Error: framing, plus
# its trailing "(try to add ...)" hint line, which the module's own
# parse (and krikri's depsolve_failure_msg) deliberately leaves out.
private ISSUE280_DEPSOLVE_STDERR = [
  "Error: ",
  ISSUE280_PROBLEM_BLOCK,
  "(try to add '--skip-broken' to skip uninstallable packages or '--nobest' to use not only best candidate packages)",
].join("\n")

# The module's own catch ("Depsolve Error occurred: " + the exception),
# not the CLI's trailing "(try to add ..." hint line.
private ISSUE280_DEPSOLVE_MSG = "Depsolve Error occurred: \n" + ISSUE280_PROBLEM_BLOCK

private ISSUE280_RPM = <<-'SH'
#!/bin/sh
[ "$2" = "--whatprovides" ] || exit 1
for n in ${KRIKRI_FAKE_RPM_PROVIDES:-}; do
  [ "$3" = "$n" ] && exit 0
done
exit 1
SH

private ISSUE280_DNF = <<-'SH'
#!/bin/sh
# Logs EVERY voyage including the availability probe (unlike the
# shared RECORDING_DNF above) so these specs can assert the exact
# question dnf got asked before anything was installed.
printf '%s\n' "$*" >> "${KRIKRI_FAKE_DNF_LOG:?}"
case "$2/$3" in
  "list/--available")
    for n in ${KRIKRI_FAKE_DNF_AVAILABLE:-}; do
      [ "$4" = "$n" ] && exit 0
    done
    exit 1
    ;;
esac
if [ -n "${KRIKRI_FAKE_DNF_DEPSOLVE:-}" ]; then
  printf '%s\n' "${KRIKRI_FAKE_DNF_DEPSOLVE}" >&2
  exit 1
fi
echo "Installed:"
echo "  fake-pkg"
exit 0
SH

# Installs the dispatching fake rpm/dnf and a fresh argv log at the
# front of PATH. Unlike #with_recording_pkg_managers this dummy dnf
# logs EVERY invocation including the availability probe, so a spec
# can assert the exact probe/install sequence. Like the helper above,
# everything travels through ENV, so the whole block holds ENV_MUTEX
# against the parallel workers.
private def with_issue280_pkg_managers(provides : Array(String) = [] of String, available : Array(String) = [] of String, depsolve : Bool = false, &)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    bin_dir = File.tempname("krikri-issue280-fakes")
    Dir.mkdir_p(bin_dir)
    rpm = File.join(bin_dir, "rpm")
    File.write(rpm, ISSUE280_RPM)
    File.chmod(rpm, 0o755)
    dnf = File.join(bin_dir, "dnf")
    File.write(dnf, ISSUE280_DNF)
    File.chmod(dnf, 0o755)

    log = File.tempname("krikri-issue280-dnf-log")
    previous_path = ENV["PATH"]?
    previous_log = ENV["KRIKRI_FAKE_DNF_LOG"]?
    previous_provides = ENV["KRIKRI_FAKE_RPM_PROVIDES"]?
    previous_available = ENV["KRIKRI_FAKE_DNF_AVAILABLE"]?
    previous_depsolve = ENV["KRIKRI_FAKE_DNF_DEPSOLVE"]?
    ENV["PATH"] = "#{bin_dir}:#{ENV["PATH"]?}"
    ENV["KRIKRI_FAKE_DNF_LOG"] = log
    ENV["KRIKRI_FAKE_RPM_PROVIDES"] = provides.join(" ")
    ENV["KRIKRI_FAKE_DNF_AVAILABLE"] = available.join(" ")
    ENV["KRIKRI_FAKE_DNF_DEPSOLVE"] = depsolve ? ISSUE280_DEPSOLVE_STDERR : ""
    begin
      yield log
    ensure
      previous_path ? (ENV["PATH"] = previous_path) : ENV.delete("PATH")
      previous_log ? (ENV["KRIKRI_FAKE_DNF_LOG"] = previous_log) : ENV.delete("KRIKRI_FAKE_DNF_LOG")
      previous_provides ? (ENV["KRIKRI_FAKE_RPM_PROVIDES"] = previous_provides) : ENV.delete("KRIKRI_FAKE_RPM_PROVIDES")
      previous_available ? (ENV["KRIKRI_FAKE_DNF_AVAILABLE"] = previous_available) : ENV.delete("KRIKRI_FAKE_DNF_AVAILABLE")
      previous_depsolve ? (ENV["KRIKRI_FAKE_DNF_DEPSOLVE"] = previous_depsolve) : ENV.delete("KRIKRI_FAKE_DNF_DEPSOLVE")
      FileUtils.rm_r(bin_dir)
      File.delete(log) if File.exists?(log)
    end
  end
end

describe "dnf plugin - same-name repo package vs a Provides: match (issue 280)" do
  it "sends an available-name package to the install batch despite a Provides: match" do
    with_issue280_pkg_managers(provides: ["curl"], available: ["curl"]) do |log|
      result = PluginSpecHelper.run("dnf", {"name" => "curl", "state" => "present"})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      File.read_lines(log).must_equal([
        "-q list --available curl",
        "install #{BASELINE_OPTIONS} curl",
      ])
    end
  end

  it "keeps a purely virtual name on the Provides: fallback (no repo row)" do
    with_issue280_pkg_managers(provides: ["php-json"], available: [] of String) do |log|
      result = PluginSpecHelper.run("dnf", {"name" => "php-json", "state" => "present"})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      # The probe finds no repo row, so the name stays 'installed' via
      # its Provides: and no install transaction may run.
      File.read_lines(log).must_equal(["-q list --available php-json"])
    end
  end

  it "fails the [curl, gcc] batch with dnf's own depsolve error, like real dnf" do
    with_issue280_pkg_managers(provides: ["curl"], available: ["curl", "gcc"], depsolve: true) do |log|
      result = PluginSpecHelper.run("dnf", {"name" => %(["curl", "gcc"]), "state" => "present"})
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(ISSUE280_DEPSOLVE_MSG)
      result["failures"].as_a.map(&.as_s).must_equal([] of String)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.keys.first(6).must_equal Krikri::PluginHelpers::DnfInstallFailures::DNF_DEPSOLVE_FAILURE_ORDER
      # Both names travel in ONE install batch - the divergence seen on
      # the real host was gcc silently installing on its own while the
      # batch only ever saw gcc.
      File.read_lines(log).last.must_equal(
        "install #{BASELINE_OPTIONS} curl gcc")
      File.read_lines(log).first(2).must_equal([
        "-q list --available curl",
        "-q list --available gcc",
      ])
    end
  end
end
