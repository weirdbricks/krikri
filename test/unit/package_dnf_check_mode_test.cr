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
  probe_results : Array(String)? = nil,
  file_nevra : String = "",
  &
)
  bin_dir = File.join(Dir.tempdir, "krikri-pkg753-#{Random.rand(1_000_000)}")
  log = File.join(bin_dir, "calls.log")
  FileUtils.mkdir_p(bin_dir)

  rpm_shim = <<-'SH'
    #!/bin/sh
    if [ "$1" = "-qp" ]; then
      [ -f "$4" ] || exit 1
      printf '%s\n' "${KRIKRI_RPM_FILE_NEVRA:-}"
      exit 0
    fi
    if [ "$2" = "--whatprovides" ]; then
      for n in ${KRIKRI_RPM_PROVIDES:-}; do
        [ "$3" = "$n" ] && exit 0
      done
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

  # The would-transaction probe shells out to the target's python-dnf
  # (issue #1038); on the spec host there is no dnf module, so a canned
  # python3 stands in for it (its first interpreter candidate, and the
  # one the probe chain stops at when it answers).
  if probe_results
    probe_json = {"results" => probe_results}.to_json
    File.write(File.join(bin_dir, "python3"), "#!/bin/sh\nprintf '%s\\n' '#{probe_json}'\n")
    File.chmod(File.join(bin_dir, "python3"), 0o755)
  end

  env = {
    "PATH"                        => "#{bin_dir}:/usr/bin:/bin",
    "KRIKRI_DNF_LOG"              => log,
    "KRIKRI_RPM_INSTALLED"        => installed.join(" "),
    "KRIKRI_RPM_FILE_NEVRA"       => file_nevra,
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

# Issue #1038 (archf.packages, Rocky 9, round29903334): with one
# unresolvable spec among many resolvable ones, real ansible records the
# bad spec into `failures` and STILL depsolves the survivors, so the
# "Failed to install some of the specified packages" failure carries the
# WHOLE would-transaction in `results` - every dependency, in dnf's own
# package-set iteration order (live-captured: 255 "Installed: <nevra>"
# entries on a 26-spec request) - under --check and in real runs alike.
# This engine reported `results: []` there; the entries now come from
# DnfTransactionProbe (canned here through the python3 shim).
# The canned would-transaction the python3 probe shim answers with
# (issue #1038's shape: the failure's `results` naming the resolved
# transaction in dnf's own package-set order).
PROBE1038_RESULTS = [
  "Installed: vim-8.2.2637-26.el9_8.23.x86_64",
  "Installed: vim-common-2:8.2.2637-26.el9_8.23.noarch",
  "Removed: vim-filesystem-2:8.2.2637-1.el9.noarch",
]

describe "package plugin - dnf failed install carries the would-transaction (issue 1038)" do
  it "check mode reports the would-transaction results on the missing-spec failure" do
    with_package753_shims(
      [] of String,
      ["vim=8.2.2637-26.el9_8.23"],
      install_out: "No match for argument: no-such-pkg\n",
      install_err: "Error: Unable to find a match: no-such-pkg\n",
      install_rc: 1,
      probe_results: PROBE1038_RESULTS,
    ) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "[\"vim\", \"no-such-pkg\"]",
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package no-such-pkg available."])
      result["results"].as_a.map(&.as_s).must_equal(PROBE1038_RESULTS)
      result["rc"].as_i.must_equal(1)
      result.as_h.keys.first(5).must_equal(["msg", "failures", "results", "rc", "failed"])
    end
  end

  it "a real run reports the same would-transaction results on the same failure" do
    with_package753_shims(
      [] of String,
      ["vim=8.2.2637-26.el9_8.23"],
      install_out: "No match for argument: no-such-pkg\n",
      install_err: "Error: Unable to find a match: no-such-pkg\n",
      install_rc: 1,
      probe_results: PROBE1038_RESULTS,
    ) do |env|
      result = PluginSpecHelper.run("package", {
        "name"         => "[\"vim\", \"no-such-pkg\"]",
        "state"        => "latest",
        "use"          => "dnf",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package no-such-pkg available."])
      result["results"].as_a.map(&.as_s).must_equal(PROBE1038_RESULTS)
      result["rc"].as_i.must_equal(1)
    end
  end

  it "keeps results: [] when no python-dnf probe can answer (the issue #19 shape)" do
    with_package753_shims(
      [] of String,
      ["vim=8.2.2637-26.el9_8.23"],
      install_out: "No match for argument: no-such-pkg\n",
      install_err: "Error: Unable to find a match: no-such-pkg\n",
      install_rc: 1,
    ) do |env|
      result = PluginSpecHelper.run("package", {
        "name"                => "[\"vim\", \"no-such-pkg\"]",
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["results"].as_a.must_equal([] of JSON::Any)
    end
  end
end

# Issue #1187 (zhan9san.jenkins, round29908273, rocky, --check): the role
# installs its pinned jenkins by local path (`package: name:
# /tmp/jenkins-2.541.3-1.noarch.rpm, state: present`), and by the check
# run the file's own header NEVRA was already installed - real's dnf
# resolves an install of an identical NEVRA to the EMPTY transaction, so
# ansible-playbook --check reported ok, where this engine's check-mode
# plan classified every URL/file spec as "would install" and reported
# changed. The verdict comes from rpm_file_already_installed? (same as
# the dnf:/yum: plugins' own issue #781 fix), and real's "Installed
# <filename>" results entry rides on every local file spec whether or
# not the transaction is empty (issue #844). Live-verified vs
# ansible-core 2.15.13 on a rockylinux:9 container (the issue's task,
# `name:` pointing at a dnf-downloaded tree/tmux rpm):
#   present, file NEVRA installed, --check -> ok: {"changed": false,
#       "msg": "Nothing to do", "rc": 0, "results": ["Installed /tmp/
#       tree-1.8.0-10.el9.x86_64.rpm"]}
#   present, file NEVRA not installed, --check -> changed, results
#       ["Installed /tmp/tmux-3.2a-5.el9.x86_64.rpm", "Installed:
#       tmux-3.2a-5.el9.x86_64"]
#   latest, file NEVRA installed, --check -> the same ok no-op (real's
#       dnf.py routes filenames through the identical install path for
#       state: latest)
describe "package plugin - check mode resolves an rpm file against the installed set (issue 1187)" do
  it "present for an already-installed local rpm file is the no-op ok, not changed" do
    with_package753_shims(["tree-1.8.0-10.el9.x86_64=tree-1.8.0-10.el9.x86_64"], [] of String,
      file_nevra: "tree-1.8.0-10.el9.x86_64") do |env|
      rpm = PluginSpecHelper.tmp_path("tree-1.8.0-10.el9.x86_64.rpm")
      File.write(rpm, "not a real rpm - the shims never parse it")
      result = PluginSpecHelper.run("package", {
        "name"                => rpm,
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.map(&.as_s).must_equal(["Installed #{rpm}"])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "present for a pending local rpm file reports the would-install shape with real's filename entry" do
    with_package753_shims([] of String, [] of String,
      file_nevra: "tmux-3.2a-5.el9.x86_64") do |env|
      rpm = PluginSpecHelper.tmp_path("tmux-3.2a-5.el9.x86_64.rpm")
      File.write(rpm, "not a real rpm - the shims never parse it")
      result = PluginSpecHelper.run("package", {
        "name"                => rpm,
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Installed #{rpm}", "Installed: tmux-3.2a-5.el9.x86_64"])
      result["rc"].as_i.must_equal(0)
    end
  end

  it "latest for an already-installed local rpm file is the same no-op ok" do
    with_package753_shims(["tree-1.8.0-10.el9.x86_64=tree-1.8.0-10.el9.x86_64"], [] of String,
      file_nevra: "tree-1.8.0-10.el9.x86_64") do |env|
      rpm = PluginSpecHelper.tmp_path("tree-1.8.0-10.el9.x86_64.rpm")
      File.write(rpm, "not a real rpm - the shims never parse it")
      result = PluginSpecHelper.run("package", {
        "name"                => rpm,
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.map(&.as_s).must_equal(["Installed #{rpm}"])
      result["rc"].as_i.must_equal(0)
    end
  end
end
