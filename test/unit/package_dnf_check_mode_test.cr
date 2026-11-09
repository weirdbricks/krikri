require "../minitest_helper"
require "file_utils"
require "json"

# Issue #753: under --check, `ansible.builtin.package` on a dnf backend
# used to report an invented "Would install/remove ... (check mode)" msg
# with NO `results` or `rc` keys, where real ansible's dnf module
# registers the module's own response dict - rc 0 and `results` naming
# every RPM the transaction WOULD have touched - so playbooks reading
# `result.results` died with "dict has no attribute 'results'".
#
# Real shapes (live-verified vs ansible-core 2.19.11 on a Rocky 9
# container, all in check mode):
#   present, spec missing from the repos     -> the ordinary install
#       failure (failures ["No package X available."], rc 1)
#   present, all installed                   -> msg "Nothing to do",
#       results [], rc 0
#   present, not installed                   -> msg "Check mode: No
#       changes made, but would have if not in check mode", results
#       ["Installed: <nevra>"], rc 0
#   absent, installed / partially installed  -> "Removed: <installed
#       nevra>" entries, with dnf's own "No match for argument: <spec>"
#       lines leading the list for specs nothing owns
#   absent, nothing installed                -> msg "Nothing to do",
#       results ["No match for argument: <spec>"], rc 0
#   latest, pending updates                  -> every "Installed: <new
#       nevra>" first (alphabetical), then every "Removed: <old nevra>"
#   latest, nothing pending / all current    -> msg "Nothing to do",
#       results [], rc 0
#   latest, not installed                    -> "Installed: <repo nevra>"
#
# The NEVRA carries the epoch where rpm -q's default output omits it
# ("tar-2:1.34-13.el9_8.x86_64"), so the shims answer in full-NEVRA
# queryformat. dnf/rpm are not on the spec host; everything runs against
# shimmed binaries on PATH (same method as the issue-732/wildcard
# tests), with per-test env passed through the plugin's _environment -
# no process-wide ENV mutation, so no serial! is needed.
private def with_package753_shims(
  installed : Array(String),
  available : Array(String),
  check_update_out : String = "",
  check_update_rc : Int32 = 0,
  provides : Array(String) = [] of String,
  install_out : String = "",
  install_err : String = "",
  install_rc : Int32 = 1,
  metadata_err : String = "",
  &
)
  bin_dir = File.join(Dir.tempdir, "krikri-pkg753-#{Random.rand(1_000_000)}")
  log = File.join(bin_dir, "calls.log")
  FileUtils.mkdir_p(bin_dir)

  rpm_shim = <<-'SH'
    #!/bin/sh
    if [ "$2" = "--whatprovides" ]; then
      for n in ${KRIKRI_RPM_PROVIDES:-}; do
        [ "$3" = "$n" ] && exit 0
      done
      exit 1
    fi
    for pair in ${KRIKRI_RPM_INSTALLED:-}; do
      pkg="${pair%%=*}"; nevra="${pair#*=}"
      [ "$4" = "$pkg" ] && { printf '%s\n' "$nevra"; exit 0; }
    done
    exit 1
    SH

  dnf_shim = <<-'SH'
    #!/bin/sh
    printf '%s\n' "$*" >> "${KRIKRI_DNF_LOG:?}"
    case "$1" in
      makecache)
        if [ -n "${KRIKRI_DNF_METADATA_ERR:-}" ]; then
          printf '%b' "${KRIKRI_DNF_METADATA_ERR}" >&2
          exit 1
        fi
        echo "Metadata cache created"
        exit 0
        ;;
      check-update)
        printf '%b' "${KRIKRI_DNF_CHECK_UPDATE_OUT:-}"
        exit "${KRIKRI_DNF_CHECK_UPDATE_RC:-0}"
        ;;
      install|upgrade)
        if [ -n "${KRIKRI_DNF_INSTALL_OUT:-}" ] || [ -n "${KRIKRI_DNF_INSTALL_ERR:-}" ]; then
          printf '%b' "${KRIKRI_DNF_INSTALL_OUT:-}"
          printf '%b' "${KRIKRI_DNF_INSTALL_ERR:-}" >&2
          exit "${KRIKRI_DNF_INSTALL_RC:-1}"
        fi
        ;;
    esac
    case "$2/$3" in
      "list/--available")
        for pair in ${KRIKRI_DNF_AVAILABLE:-}; do
          pkg="${pair%%=*}"; evr="${pair#*=}"
          [ "$4" = "$pkg" ] && { printf 'Available Packages\n%s.x86_64 %s fakerepo\n' "$pkg" "$evr"; exit 0; }
        done
        exit 1
        ;;
      "provides/"*)
        for pair in ${KRIKRI_DNF_PROVIDES:-}; do
          cap="${pair%%=*}"; nevra="${pair#*=}"
          [ "$3" = "$cap" ] && {
            printf 'Repo        : fakerepo\nMatched from:\nProvide    : %s\n\n%s : a capability provider\n' "$cap" "$nevra"
            exit 0
          }
        done
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
    "PATH"                        => "#{bin_dir}:/usr/bin:/bin",
    "KRIKRI_DNF_LOG"              => log,
    "KRIKRI_RPM_INSTALLED"        => installed.join(" "),
    "KRIKRI_DNF_AVAILABLE"        => available.join(" "),
    "KRIKRI_DNF_PROVIDES"         => provides.join(" "),
    "KRIKRI_DNF_CHECK_UPDATE_OUT" => check_update_out,
    "KRIKRI_DNF_CHECK_UPDATE_RC"  => check_update_rc.to_s,
    "KRIKRI_DNF_INSTALL_OUT"      => install_out,
    "KRIKRI_DNF_INSTALL_ERR"      => install_err,
    "KRIKRI_DNF_INSTALL_RC"       => install_rc.to_s,
    "KRIKRI_DNF_METADATA_ERR"     => metadata_err,
  }.to_json
  yield env
ensure
  FileUtils.rm_rf(bin_dir) if bin_dir
end

# A real rockylinux:9 check-update capture shape: one zero-epoch pending
# upgrade (gawk) and one epoch-carrying one (tar), both installed at
# older releases per KRIKRI_RPM_INSTALLED.
private def pkg753_check_update_out : String
  "Last metadata expiration check: 0:00:17 ago on Mon Nov  2 20:06:44 2026.\n" \
  "\n" \
  "gawk.x86_64                       5.1.0-6.el9_8.1             baseos\n" \
  "tar.x86_64                        2:1.34-13.el9_8             baseos\n"
end

private def pkg753_installed_pair : Array(String)
  ["tar=tar-2:1.34-11.el9.x86_64", "gawk=gawk-5.1.0-6.el9.x86_64", "vim=vim-8.2.2637-1.el9.x86_64"]
end

private def pkg753_available_pair : Array(String)
  ["tar=2:1.34-13.el9_8", "gawk=5.1.0-6.el9_8.1", "chrony=4.8-1.el9"]
end

describe "package plugin - dnf check-mode result shapes (issue 753)" do
  it "latest with pending updates registers the module's results/rc keys (the issue's repro shape)" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair, pkg753_check_update_out, 100) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "[\"tar\", \"gawk\"]",
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      # The controller appends `failed: false` after the plugin's keys -
      # the dnf4 module's own response-dict order (msg first).
      result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      # Every "Installed:" entry first (alphabetical, like dnf's own
      # transaction iteration), then every "Removed:" entry - with the
      # epoch spelled the way real's entries spell it.
      result["results"].as_a.map(&.as_s).must_equal([
        "Installed: gawk-5.1.0-6.el9_8.1.x86_64",
        "Installed: tar-2:1.34-13.el9_8.x86_64",
        "Removed: gawk-5.1.0-6.el9.x86_64",
        "Removed: tar-2:1.34-11.el9.x86_64",
      ])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "latest with everything current is the ordinary no-op shape, not an invented msg" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "vim",
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(0)
    end
  end

  it "latest for a not-installed package reports the would-be install nevra" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "chrony",
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Installed: chrony-4.8-1.el9.x86_64"])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "present for a not-installed package reports the would-be install nevra" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "chrony",
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Installed: chrony-4.8-1.el9.x86_64"])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "present with everything already installed is the ordinary no-op shape" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "tar",
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(0)
    end
  end

  it "absent for an installed package reports the removed nevra with the epoch" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "tar",
        "state"               => "absent",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Removed: tar-2:1.34-11.el9.x86_64"])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "absent for a package nothing owns reports dnf's own no-match line and the no-op msg" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "chrony",
        "state"               => "absent",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.map(&.as_s).must_equal(["No match for argument: chrony"])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "absent for a mixed request puts the no-match lines before the removals" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "[\"tar\", \"chrony\"]",
        "state"               => "absent",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal([
        "No match for argument: chrony",
        "Removed: tar-2:1.34-11.el9.x86_64",
      ])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "present for a capability the repos provide reports the would-be install nevra (issue 907)" do
    # Real ansible's dnf backend hands `perl(Devel::Cover)` to
    # python-dnf, which resolves a Provides: spec to the archive's
    # perl-Devel-Cover and reports changed: true - `dnf list --available`
    # can't answer for a capability, so this used to be classified
    # Missing and hard-failed with "No package ... available.".
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair,
      provides: ["perl(Devel::Cover)=perl-Devel-Cover-1.40-1.el9.x86_64"]) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "perl(Devel::Cover)",
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Installed: perl-Devel-Cover-1.40-1.el9.x86_64"])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "fails an unresolvable spec with the install-failure shape, like the real install does" do
    # Live-verified vs 2.19.11 in check mode too: the transaction
    # resolution fails the task before any check-mode stop, with the
    # same failures/msg/rc/results shape the non-check install reports.
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "totally-bogus-pkg-753",
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package totally-bogus-pkg-753 available."])
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
    end
  end
end

# Issue #1050 (kurron.resilio-sync, Rocky 9): under --check, `package:
# name: "{{item}}"` on `curl` reported changed where real ansible's dnf
# module failed the task with the Depsolve Error block - dnf.py resolves
# the whole transaction (base.resolve()) BEFORE its check-mode stop, and
# the installed curl-minimal makes installing curl unsatisfiable. This
# engine's check-mode branches never ran that resolution. The Problem
# block below is trimmed from the round's live capture (ansible-core
# 2.21.6 on Rocky 9); depsolve_failure_msg lifts it verbatim and stops at
# the blank line before dnf's "(try to add ...)" hint.
ISSUE1050_DEPSOLVE_STDERR = "Error: \n Problem: problem with installed package curl-minimal-7.76.1-40.el9.x86_64\n  - package curl-minimal-7.76.1-40.el9.x86_64 from @System conflicts with curl provided by curl-7.76.1-40.el9_8.9.x86_64 from baseos\n  - cannot install the best candidate for the job\n"
ISSUE1050_DEPSOLVE_MSG    = "Depsolve Error occurred: \n Problem: problem with installed package curl-minimal-7.76.1-40.el9.x86_64\n  - package curl-minimal-7.76.1-40.el9.x86_64 from @System conflicts with curl provided by curl-7.76.1-40.el9_8.9.x86_64 from baseos\n  - cannot install the best candidate for the job"

describe "package plugin - check-mode resolution probe (issue 1050)" do
  it "present with a solver-unsatisfiable goal fails with the depsolve shape, not changed" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair,
      install_err: ISSUE1050_DEPSOLVE_STDERR) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "chrony",
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(ISSUE1050_DEPSOLVE_MSG)
      # ansible-core 2.21's empty-failures fail_json wrapper (issue
      # #989): alphabetical changed/msg/rc/results, `failed` trailing.
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
      result["rc"].as_i.must_equal(1)
      result["results"].as_a.must_equal([] of JSON::Any)
    end
  end

  it "present with a resolvable goal keeps the would-install shape when the probe aborts" do
    # The --assumeno probe reproduces dnf.py's resolve-and-stop: a
    # solvable goal ends "Operation aborted." rc 1 without installing
    # anything (live-verified vs dnf 4 on Rocky 9), which must never be
    # read as a failure.
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair,
      install_out: "Operation aborted.\n", install_rc: 1) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "chrony",
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Installed: chrony-4.8-1.el9.x86_64"])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "latest with a solver-unsatisfiable goal fails with the depsolve shape too" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair, pkg753_check_update_out, 100,
      install_err: ISSUE1050_DEPSOLVE_STDERR) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "chrony",
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(ISSUE1050_DEPSOLVE_MSG)
      result["rc"].as_i.must_equal(1)
    end
  end
end

# Issue #1031 (aaditya2801.k8s_master, Rocky --check): ansible's dnf
# module Base fill_sack()s EVERY enabled repo before it resolves
# anything, so the role's dead kubernetes repo (repomd.xml 404s) failed
# every `package: {name: "{{ item }}", state: present}` loop item under
# --check with libdnf's bare metadata msg - including the item the repos
# could not name at all - where this engine's check-mode plan answered
# the canned "No package kubeadm available." failures built from
# classification probes that never load the repo metadata. Live-
# captured from the issue's round and re-verified against ansible-core
# 2.21.6 on a rockylinux:9 container with the role's own repo file:
#   failed: [testhost] (item=kubeadm) => {"changed": false, "msg":
#   "Failed to download metadata for repo 'kubernetes': Cannot download
#   repomd.xml: Cannot download repodata/repomd.xml: All mirrors were
#   tried", "rc": 1, "results": []}
ISSUE1031_METADATA_MSG    = "Failed to download metadata for repo 'kubernetes': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried"
ISSUE1031_METADATA_STDERR = "Errors during downloading metadata for repository 'kubernetes':\n" \
                            "  - Status code: 404 for https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64/repodata/repomd.xml (IP: 142.251.210.78)\n" \
                            "Error: " + ISSUE1031_METADATA_MSG + "\n"

describe "package plugin - the fill_sack repo-metadata load fails every request (issue 1031)" do
  it "check-mode present for a name the repos cannot name reports the metadata shape" do
    # kubeadm: not installed and no repo row (the dead kubernetes repo
    # hid it), so the old check-mode plan built "No package kubeadm
    # available." where ansible fails on the metadata.
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair,
      metadata_err: ISSUE1031_METADATA_STDERR) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "kubeadm",
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(ISSUE1031_METADATA_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("failures").must_equal(false)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "check-mode absent reports the metadata shape instead of a would-remove plan" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair,
      metadata_err: ISSUE1031_METADATA_STDERR) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "tar",
        "state"               => "absent",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(ISSUE1031_METADATA_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
    end
  end

  it "a nameless invocation reports the metadata shape instead of the Nothing-to-do ok" do
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair,
      metadata_err: ISSUE1031_METADATA_STDERR) do |env|
      result = PluginSpecHelper.run("package", {
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(ISSUE1031_METADATA_MSG)
      result["rc"].as_i.must_equal(1)
    end
  end

  it "state: latest reports the metadata shape instead of the Nothing-to-do ok" do
    # The latest branch's own check-update loads the same repo metadata,
    # so its failure text preempts the per-spec plan for free.
    with_package753_shims(pkg753_installed_pair, pkg753_available_pair,
      check_update_out: ISSUE1031_METADATA_STDERR, check_update_rc: 1) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "tar",
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(ISSUE1031_METADATA_MSG)
      result["rc"].as_i.must_equal(1)
    end
  end
end
