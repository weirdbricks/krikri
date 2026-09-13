require "../spec_helper"
require "file_utils"

# Proactive parameter-coverage pass for the dnf/yum plugin family
# (src/krikri/plugin_helpers/rpm_package.cr's build_dnf_options).
#
# dnf/rpm are NOT installed on the spec host (Debian-based), so these
# specs pin the CLI-invocation SHAPE only: a fake `dnf`/`rpm` on PATH
# records the argv the plugin builds, and each example asserts the exact
# flag string for the params under test - "given these params, is the
# constructed command line correct" rather than "does dnf behave this
# way". Every expected flag was cross-checked against the locally
# installed real ansible-core's own dnf.py module source
# (/usr/lib/python3/dist-packages/ansible/modules/dnf.py), not against
# a live dnf run - see the per-example comments for which claims come
# from that source vs. dnf's documented CLI surface (general dnf
# knowledge, not live-verified on this machine).

RECORDING_DNF = <<-'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${KRIKRI_FAKE_DNF_LOG:-/dev/null}"
echo "Installed:"
echo "  fake-pkg"
exit 0
SH

FAILING_RPM = "#!/bin/sh\nexit 1\n"

# Installs fake `dnf` (records its full argv, one invocation per line)
# and `rpm` (always "not installed", so every spec lands on the install
# path) at the front of PATH.
def with_recording_pkg_managers(&)
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

# The plugin's baseline option string with none of the new params set:
# -y (non-interactive), the localpkg_gpgcheck forcing from the earlier
# GPG-audit pass, and the historical unconditional `--best` (dnf's own
# built-in default; real Ansible's best/nobest default is
# OS-distribution-dependent, so nothing better can be pinned without
# an OS-specific check).
BASELINE_OPTIONS = "-y --setopt=localpkg_gpgcheck=1 --best"

def recorded_install_command(log : String, invocations : Int32 = 1) : String
  lines = File.read_lines(log)
  lines.size.should eq(invocations)
  lines[invocations - 1]
end

describe "dnf plugin - parameter coverage (CLI-invocation shape)" do
  it "builds the documented baseline when none of the new params are set" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {"name" => "fake-pkg", "state" => "present"})
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install #{BASELINE_OPTIONS} fake-pkg")
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install #{BASELINE_OPTIONS} --allowerasing fake-pkg")
    end
  end

  # dnf.py _configure_base: `conf.best = not self.nobest` when nobest is
  # given, `conf.best = self.best` otherwise; the two are mutually
  # exclusive in the shared yumdnf argument spec, and the documented
  # default is "set by the operating system distribution" (nothing
  # emitted). dnf's CLI accepts both --best and --nobest.
  it "maps best: false to --nobest" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"  => "fake-pkg",
        "state" => "present",
        "best"  => "false",
      })
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install -y --setopt=localpkg_gpgcheck=1 --nobest fake-pkg")
    end
  end

  it "maps best: true to --best" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"  => "fake-pkg",
        "state" => "present",
        "best"  => "true",
      })
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install #{BASELINE_OPTIONS} fake-pkg")
    end
  end

  it "maps nobest: true to --nobest (the inverted form of best:)" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"   => "fake-pkg",
        "state"  => "present",
        "nobest" => "true",
      })
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install -y --setopt=localpkg_gpgcheck=1 --nobest fake-pkg")
    end
  end

  it "maps nobest: false to --best" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"   => "fake-pkg",
        "state"  => "present",
        "nobest" => "false",
      })
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install #{BASELINE_OPTIONS} fake-pkg")
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install #{BASELINE_OPTIONS} --cacheonly fake-pkg")
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install #{BASELINE_OPTIONS} --config=/etc/dnf/other.conf fake-pkg")
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install #{BASELINE_OPTIONS} --disableexcludes=main fake-pkg")
    end
  end

  # dnf.py _base: `base.init_plugins(set(self.disable_plugin),
  # set(self.enable_plugin))` - dnf's --enableplugin/--disableplugin,
  # per-transaction only. List params can arrive as a JSON array string
  # (how the PluginManager serializes lists) or a comma-separated string
  # (real Ansible's own listify_comma_sep_strings_in_list).
  it "expands enable_plugin/disable_plugin (JSON array form) to one flag per name" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"           => "fake-pkg",
        "state"          => "present",
        "enable_plugin"  => %(["versionlock", "supspeed"]),
        "disable_plugin" => %(["fastestmirror"]),
      })
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq(
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq(
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq(
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq(
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq(
        "install #{BASELINE_OPTIONS} --installroot=/mnt/sysimage fake-pkg")

      result2 = PluginSpecHelper.run("dnf", {
        "name"        => "fake-pkg",
        "state"       => "present",
        "installroot" => "/",
      })
      result2["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log, 2).should eq("install #{BASELINE_OPTIONS} fake-pkg")
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq(
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq(
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq(
        "install #{BASELINE_OPTIONS} --downloadonly --downloaddir=/tmp/rpms fake-pkg")

      # download_dir without download_only has no effect - exactly as in
      # real Ansible (conf.destdir is only set when download_only is set).
      result2 = PluginSpecHelper.run("dnf", {
        "name"         => "fake-pkg",
        "state"        => "present",
        "download_dir" => "/tmp/rpms",
      })
      result2["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log, 2).should eq("install #{BASELINE_OPTIONS} fake-pkg")
    end
  end

  # install_repoquery / validate_certs / lock_timeout are accepted
  # no-ops for the dnf backend, matching real ansible-core's own dnf.py:
  # - install_repoquery is documented as "effectively a no-op in DNF"
  #   (deprecated, removal slated for ansible-core 2.20);
  # - validate_certs only applies controller-side when real Ansible
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
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install #{BASELINE_OPTIONS} fake-pkg")
    end
  end

  # dnf.py's argument spec: use_backend choices are
  # ['auto', 'dnf', 'yum', 'yum4', 'dnf4', 'dnf5'] and real Ansible
  # fails anything else with the standard choices-validation message
  # before module code runs. Valid choices are accepted, then no-op:
  # krikri has a single dnf implementation to route to.
  it "validates use_backend against real Ansible's choice list" do
    with_recording_pkg_managers do |log|
      result = PluginSpecHelper.run("dnf", {
        "name"        => "fake-pkg",
        "state"       => "present",
        "use_backend" => "dnf5",
      })
      result["failed"]?.try(&.as_bool).should be_falsey
      recorded_install_command(log).should eq("install #{BASELINE_OPTIONS} fake-pkg")

      bad = PluginSpecHelper.run("dnf", {
        "name"        => "fake-pkg",
        "state"       => "present",
        "use_backend" => "portage",
      })
      bad["failed"].as_bool.should be_true
      bad["msg"].as_s.should eq(
        "value of use_backend must be one of: auto, dnf, yum, yum4, dnf4, dnf5, got: portage")
      File.read_lines(log).size.should eq(1)
    end
  end
end
