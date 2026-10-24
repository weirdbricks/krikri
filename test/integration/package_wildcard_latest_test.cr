require "../minitest_helper"
require "file_utils"

# `package: {name: "*", state: latest}` on an apt host. Ansible's apt.py
# (the backend `package:` delegates to) has its own
# `if latest and all_installed:` branch that runs upgrade(module, 'yes',
# ...) - the same command `upgrade: yes` builds - and never a
# per-package `apt-get install *`: apt-get treats a bare `*` as a glob
# over EVERY package in the archive, so on a host with a held/conflicting
# package pair it drags in packages a real `apt-get upgrade` never
# touches and fails with "E: Unable to correct problems, you have held
# broken packages" where Ansible reports a clean upgrade (found via
# MindPointGroup.ubuntu22_cis's "1.2.2.1 | PATCH | Ensure updates, patches
# and additional security software are installed" task, round 1500409).
#
# Builds a stub PATH dir whose `apt-get` logs every invocation to
# $KRIKRI_APT_CALLS, prints $KRIKRI_APT_UPGRADE_OUT and exits with
# $KRIKRI_APT_EXIT - so the whole dispatch is side-effect-free and the
# asserted command line is exactly what got run. Yields the
# `_environment` JSON param and the call-log path.
private def with_wildcard_shim(upgrade_output : String, exit_code : Int32 = 0, &)
  dir = File.join(Dir.tempdir, "krikri-pkg-wildcard-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  apt_shim = <<-'SHIM'
    #!/bin/sh
    echo "$@" >> "$KRIKRI_APT_CALLS"
    if [ "${KRIKRI_APT_EXIT:-0}" != "0" ]; then
      printf '%b' "$KRIKRI_APT_UPGRADE_OUT" >&2
    else
      printf '%b' "$KRIKRI_APT_UPGRADE_OUT"
    fi
    exit "${KRIKRI_APT_EXIT:-0}"
    SHIM
  File.write(File.join(dir, "apt-get"), apt_shim)
  File.chmod(File.join(dir, "apt-get"), 0o755)
  env = {
    "PATH"                   => "#{dir}:/usr/bin:/bin",
    "KRIKRI_APT_CALLS"       => log,
    "KRIKRI_APT_UPGRADE_OUT" => upgrade_output,
    "KRIKRI_APT_EXIT"        => exit_code.to_s,
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

private def wildcard_zero_output : String
  "Reading package lists...\nBuilding dependency tree...\nReading state information...\nCalculating upgrade...\n0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n"
end

describe "package plugin name:* state: latest" do
  it "runs apt-get upgrade --with-new-pkgs, never apt-get install '*'" do
    with_wildcard_shim(wildcard_zero_output) do |env, log|
      result = PluginSpecHelper.run("package", {
        "name"         => "*",
        "state"        => "latest",
        "lock_timeout" => "60",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      calls = File.read(log)
      calls.must_include("upgrade --with-new-pkgs")
      calls.wont_include(" install ")
      # A genuine no-op upgrade reports changed: false (apt.py's
      # APT_GET_ZERO exit).
      result["changed"].as_bool.must_equal(false)
    end
  end

  it "reports changed: true when the upgrade output shows upgraded packages" do
    output = "Reading package lists...\nCalculating upgrade...\nThe following packages will be upgraded:\n  libc6\n2 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n"
    with_wildcard_shim(output) do |env, _log|
      result = PluginSpecHelper.run("package", {
        "name"         => "*",
        "state"        => "latest",
        "lock_timeout" => "60",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      result["changed"].as_bool.must_equal(true)
    end
  end

  it "fails with apt.py's own '<cmd> failed: <err>' message on a non-zero rc" do
    with_wildcard_shim("E: Unable to correct problems, you have held broken packages.\n", 100) do |env, _log|
      result = PluginSpecHelper.run("package", {
        "name"         => "*",
        "state"        => "latest",
        "lock_timeout" => "60",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_match(/upgrade --with-new-pkgs.*' failed: E: Unable to correct problems/)
      result["rc"].as_i.must_equal(100)
    end
  end

  it "refuses to mix '*' with real package names, like apt.py's own fail_json" do
    with_wildcard_shim(wildcard_zero_output) do |env, log|
      result = PluginSpecHelper.run("package", {
        "name"         => "[\"*\", \"bash\"]",
        "state"        => "latest",
        "lock_timeout" => "60",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("unable to install additional packages when upgrading all installed packages")
      # Nothing ran at all - the refusal precedes every apt-get call.
      File.exists?(log).must_equal(false)
    end
  end
end

# `package: {name: "*", state: latest}` on a dnf host. Ansible's
# `package:` module delegates straight to ansible.builtin.dnf, and dnf.py
# routes this exact form through a bare base.upgrade_all() on the Python
# API - an upgrade, never an install of the glob - while that API's
# Base() never reads /etc/dnf/dnf.conf, so conf.best stays False:
# conflicting updates are silently dropped and the task ends changed, rc
# 0. The dnf CLI this module's compound runs DOES read dnf.conf (Rocky
# ships best=True in it), and the bare CLI upgrade then hard-fails with a
# Depsolve Error the Python path never sees (issue 299) - the compound
# must pin --nobest, the way plugins/dnf.cr's handle_upgrade_all already
# does for the native `dnf:` module. Same shim idea as the apt block
# above, with dnf and yum both shimmed by the same script: each records
# its argv ($* per line) and echoes the canned outputs, and dnf exiting 0
# never even reaches the `|| yum` fallback.
private def with_dnf_wildcard_shim(out_content : String, err_content : String = "", exit_code : Int32 = 0, &)
  bin_dir = File.join(Dir.tempdir, "krikri-pkg-wildcard-dnf-#{Random.rand(1_000_000)}")
  log = File.join(bin_dir, "calls.log")
  FileUtils.mkdir_p(bin_dir)
  shim = <<-'SHIM'
    #!/bin/sh
    printf '%s\n' "$*" >> "${KRIKRI_DNF_CALLS:-/dev/null}"
    [ -n "${KRIKRI_DNF_OUT:-}" ] && printf '%b' "${KRIKRI_DNF_OUT}"
    [ -n "${KRIKRI_DNF_ERR:-}" ] && printf '%b' "${KRIKRI_DNF_ERR}" >&2
    exit "${KRIKRI_DNF_EXIT:-0}"
    SHIM
  File.write(File.join(bin_dir, "dnf"), shim)
  File.write(File.join(bin_dir, "yum"), shim)
  File.chmod(File.join(bin_dir, "dnf"), 0o755)
  File.chmod(File.join(bin_dir, "yum"), 0o755)
  # `rpm` is shimmed to plain failure (any real one is absent on the spec
  # host anyway): dnf.py's upgrade_all() never consults the rpm db for a
  # whole-inventory upgrade, so the "installed?" pre-check toggling can't
  # change what the branch is expected to run.
  rpm = File.join(bin_dir, "rpm")
  File.write(rpm, "#!/bin/sh\nexit 1\n")
  File.chmod(rpm, 0o755)
  env = {
    "PATH"             => "#{bin_dir}:/usr/bin:/bin",
    "KRIKRI_DNF_CALLS" => log,
    "KRIKRI_DNF_OUT"   => out_content,
    "KRIKRI_DNF_ERR"   => err_content,
    "KRIKRI_DNF_EXIT"  => exit_code.to_s,
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(bin_dir) if bin_dir
end

private def dnf_wildcard_noop_output : String
  "Dependencies resolved.\nNothing to do.\nComplete!\n"
end

private def dnf_wildcard_upgrade_output : String
  "Dependencies resolved.\nUpgraded:\n  glibc-2.34-125.el9_5.13.x86_64\n\nComplete!\n"
end

describe "package plugin name:* state: latest (dnf host, issue 299)" do
  it "runs dnf upgrade --nobest, never dnf install '*'" do
    with_dnf_wildcard_shim(dnf_wildcard_noop_output) do |env, log|
      result = PluginSpecHelper.run("package", {
        "name"         => "*",
        "state"        => "latest",
        "use"          => "dnf",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      # Exactly one invocation, and it is the upgrade-the-inventory
      # compound with the API path's best=False pinned onto the CLI
      # (--nobest); dnf exiting 0 also means yum's line never lands.
      File.read_lines(log).must_equal(["upgrade -y --setopt=localpkg_gpgcheck=1 --nobest"])
      # A genuine no-op upgrade-all reports changed: false - ansible's
      # base.upgrade_all() prints "Nothing to do" and ends rc 0.
      result["changed"].as_bool.must_equal(false)
    end
  end

  it "reports changed: true when the upgrade output shows upgraded packages" do
    with_dnf_wildcard_shim(dnf_wildcard_upgrade_output) do |env, _log|
      result = PluginSpecHelper.run("package", {
        "name"         => "*",
        "state"        => "latest",
        "use"          => "dnf",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      result["changed"].as_bool.must_equal(true)
    end
  end

  it "keeps state: present's gpg choice in the upgrade compound (disable_gpg_check)" do
    with_dnf_wildcard_shim(dnf_wildcard_noop_output) do |env, log|
      result = PluginSpecHelper.run("package", {
        "name"              => "*",
        "state"             => "latest",
        "use"               => "dnf",
        "disable_gpg_check" => "true",
        "_environment"      => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      File.read_lines(log).must_equal(["upgrade -y --nogpgcheck --nobest"])
      result["changed"].as_bool.must_equal(false)
    end
  end

  it "fails through the per-spec failure shape on a nonzero dnf rc" do
    with_dnf_wildcard_shim(
      "No match for argument: redhat-lsb-core\n",
      "Error: Unable to find a match: redhat-lsb-core\n", 1) do |env, _log|
      result = PluginSpecHelper.run("package", {
        "name"         => "*",
        "state"        => "latest",
        "use"          => "dnf",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package redhat-lsb-core available."])
      result["rc"].as_i.must_equal(1)
    end
  end

  it "check mode runs the whole-inventory check-update without the '*' arg" do
    with_dnf_wildcard_shim(dnf_wildcard_noop_output, "", 100) do |env, log|
      result = PluginSpecHelper.run("package", {
        "name"                => "*",
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Would update * to latest (check mode)")
      # One invocation, and no literal '*' name spec reaches check-update.
      File.read_lines(log).must_equal(["check-update"])
    end
  end
end
