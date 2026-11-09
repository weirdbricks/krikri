require "../minitest_helper"
require "file_utils"
require "json"
require "../../src/krikri/plugin_helpers/dnf_install_failures"

# Issue #19 (Rocky, dnf failure output gap): ansible-core 2.19's dnf
# module (dnf4 backend) reports a failed install with its own canned
# shape - msg "Failed to install some of the specified packages", one
# deduped `failures` entry per unresolvable spec parsed from dnf's
# output, results [], rc 1, key order [msg, failures, results, rc,
# failed] and NO stderr key - while this engine dumped dnf's raw
# stderr/stdout lines under "Failed to install packages". The per-spec
# wording and the modular-filtering form are live-captured from Rocky:
#
#   No match for argument: redhat-lsb-core
#   Error: Unable to find a match: redhat-lsb-core
#     -> "No package redhat-lsb-core available."
#
#   All matches were filtered out by modular filtering for argument: mysql-devel
#     -> "mysql-devel All matches were filtered out by modular filtering
#         for argument: mysql-devel"
#
# Outputs nothing in parses (repo metadata/404-class errors) keep the
# previous raw shape. Both the dnf/yum plugins and `package:`'s own
# dnf/yum shell-out must produce the identical shape.
MISSING_PKG_STDOUT = "No match for argument: redhat-lsb-core\n"
MISSING_PKG_STDERR = "Error: Unable to find a match: redhat-lsb-core\n"

MODULAR_STDOUT = "All matches were filtered out by modular filtering for argument: mysql-devel\n"
MODULAR_STDERR = "Error: All matches for argument: mysql-devel were filtered out by modular filtering\n"

# Issue #216 (Rocky 9, perl-File-Temp install walled behind exclude=perl-Carp
# in /etc/dnf/dnf.conf): the depsolve "Problem: ..." block the dnf4 CLI
# prints - twice, because `package:` shells `dnf install ... || yum install ...`
# and each binary prints its own copy - is real ansible's depsolve catch
# msg verbatim after the "Depsolve Error occurred: " prefix, NOT an input to
# the per-spec failures parser (nothing in it matches those lines). The
# resulting fatal carries no failures key: ansible-core 2.21 only
# forwards that list when it is non-empty (issue #989).
DEPSOLVE_STDERR = "Error: \n Problem: package perl-File-Temp-1:0.231.100-4.el9.noarch from appstream requires perl(Carp), but none of the providers can be installed\n  - conflicting requests\n  - package perl-Carp-1.50-460.el9.0.1.noarch from appstream is filtered out by exclude filtering\n(try to add '--skip-broken' to skip uninstallable packages or '--nobest' to use not only best candidate packages)\nError: \n Problem: package perl-File-Temp-1:0.231.100-4.el9.noarch from appstream requires perl(Carp), but none of the providers can be installed\n  - conflicting requests\n  - package perl-Carp-1.50-460.el9.0.1.noarch from appstream is filtered out by exclude filtering\n(try to add '--skip-broken' to skip uninstallable packages or '--nobest' to use not only best candidate packages)\n"
DEPSOLVE_MSG    = "Depsolve Error occurred: \n Problem: package perl-File-Temp-1:0.231.100-4.el9.noarch from appstream requires perl(Carp), but none of the providers can be installed\n  - conflicting requests\n  - package perl-Carp-1.50-460.el9.0.1.noarch from appstream is filtered out by exclude filtering"

private def with_failing_dnf_shim(stdout : String, stderr : String, &)
  shim_dir = PluginSpecHelper.tmp_path("fake-dnf-fail")
  Dir.mkdir_p(shim_dir)
  script = "#!/bin/sh\ncat <<'KRIKRI_FAKE_DNF_EOF'\n#{stdout}KRIKRI_FAKE_DNF_EOF\n"
  script += stderr.lines.map { |line| "echo '#{line.gsub("'", "'\\''")}' >&2" }.join("\n") + "\n" unless stderr.empty?
  script += "exit 1\n"
  File.write("#{shim_dir}/dnf", script)
  File.chmod("#{shim_dir}/dnf", 0o755)
  # `package:` shells `dnf install ... || yum install ...`, so yum needs
  # an equally failing shim or the compound would exit 0.
  File.write("#{shim_dir}/yum", script)
  File.chmod("#{shim_dir}/yum", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

private class DnfFailuresParseHarness
  include Krikri::PluginHelpers::DnfInstallFailures
end

describe "dnf/yum failed install - Ansible's per-spec failures shape (issue 19)" do
  serial!

  it "reports one No package X available. entry for a missing spec (dnf)" do
    with_failing_dnf_shim(MISSING_PKG_STDOUT, MISSING_PKG_STDERR) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "redhat-lsb-core", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package redhat-lsb-core available."])
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      # The real module's failure dict carries no stderr key.
      result.as_h.has_key?("stderr").must_equal(false)
      # dnf4's registered failure key order (controller-appended keys
      # trail: changed, exception).
      result.as_h.keys.first(5).must_equal(["msg", "failures", "results", "rc", "failed"])
    end
  end

  it "reports the modular-filtering wording with the spec prefix (dnf)" do
    with_failing_dnf_shim(MODULAR_STDOUT, MODULAR_STDERR) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "mysql-devel", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(
        ["mysql-devel All matches were filtered out by modular filtering for argument: mysql-devel"])
      result.as_h.has_key?("stderr").must_equal(false)
    end
  end

  it "dedupes specs dnf echoes on both the per-argument and summary lines" do
    with_failing_dnf_shim(
      "No match for argument: foo\nNo match for argument: bar\n",
      "Error: Unable to find a match: foo bar\n") do
      result = PluginSpecHelper.run("dnf",
        {"name" => "foo,bar", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failures"].as_a.map(&.as_s).must_equal(
        ["No package foo available.", "No package bar available."])
    end
  end

  it "reports an unknown group with ansible's No group ... available. msg (issue 958)" do
    # AAROC.CODE-RADE-container's `yum: name: "@X Software Development"`
    # on Rocky: ansible's dnf module resolves the group spec against comps
    # before any transaction and fails with "No group X Software
    # Development available." plus results []/rc 1 and NO failures key
    # (the module drops the empty list). dnf's CLI instead prints
    # "Module or Group '...' is not available." + "Error: Nothing to do."
    # on stderr (the metadata-check line on stdout), which used to fall
    # through to the generic "Failed to install packages" raw dump.
    with_failing_dnf_shim(
      "Last metadata expiration check: 5:05:39 ago on Sat Nov  7 19:35:22 2026.\n",
      "Module or Group 'X Software Development' is not available.\nError: Nothing to do.\n") do
      result = PluginSpecHelper.run("dnf",
        {"name" => "@X Software Development", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("No group X Software Development available.")
      result.as_h.has_key?("failures").must_equal(false)
      result.as_h.has_key?("stderr").must_equal(false)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "keeps the raw-line fallback for outputs nothing parses (dnf)" do
    # Only outputs matching NEITHER the metadata-download helper (now
    # its own ansible shape, issue 267) NOR the per-spec parser reach
    # the raw dump.
    with_failing_dnf_shim(
      "Unexpected transaction failure text that matches no known pattern\n",
      "") do
      result = PluginSpecHelper.run("dnf",
        {"name" => "redhat-lsb-core", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to install packages")
      result["failures"].as_a.map(&.as_s).must_equal(
        ["Unexpected transaction failure text that matches no known pattern"])
    end
  end

  it "reports a module-level GPG validation failure for an unsigned rpm URL (issue 60)" do
    with_failing_dnf_shim(
      "",
      "Public key for epel-release-latest-9.noarchabc.rpm is not installed. Failing package is: epel-release-9-11.el9.noarch\nError: GPG check FAILED\n") do
      # A remote name is fetched by the plugin first (ansible's fetch_file runs
      # before dnf), so the GPG path is reached with a staged local rpm.
      rpm = PluginSpecHelper.tmp_path("epel-release-latest-9.noarch.rpm")
      File.write(rpm, "")
      result = PluginSpecHelper.run("dnf",
        {"name" => rpm, "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal(
        "Failed to validate GPG signature for epel-release-9-11.el9.noarch: Public key for epel-release-latest-9.noarchabc.rpm is not installed")
      result.as_h.has_key?("failures").must_equal(false)
      result["rc"].as_i.must_equal(1)
      result["results"].as_a.must_equal([] of JSON::Any)
    end
  end

  it "reports the GPG failure with results and rc through package: (issue 980)" do
    # adipriyantobpn.repo-epel installs epel-release from its URL with
    # `yum:`; real ansible-core 2.21.6 reports the failure as
    # {"changed": false, "msg": "Failed to validate GPG signature for
    # <nevra>: <key error>", "rc": 1, "results": []} - the signature
    # check raises before any per-spec failure exists, so there is no
    # failures key, but the dnf backend's empty-failures fail_json still
    # supplies results and rc, and the key order is alphabetical.
    with_failing_dnf_shim(
      "",
      "Public key for epel-release-latest-9.noarchabc.rpm is not installed. Failing package is: epel-release-9-11.el9.noarch\nError: GPG check FAILED\n") do
      rpm = PluginSpecHelper.tmp_path("epel-release-latest-9.noarch.rpm")
      File.write(rpm, "")
      result = PluginSpecHelper.run("package",
        {"name" => rpm, "state" => "present", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(
        "Failed to validate GPG signature for epel-release-9-11.el9.noarch: Public key for epel-release-latest-9.noarchabc.rpm is not installed")
      result["rc"].as_i.must_equal(1)
      result["results"].as_a.must_equal([] of JSON::Any)
      result.as_h.has_key?("failures").must_equal(false)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "derives the GPG failure nevra from the @commandline table row (dnf 4.14)" do
    with_failing_dnf_shim(
      " Package          Arch     Version     Repository     Size\nInstalling:\n epel-release     noarch   9-11.el9    @commandline   18 k\n",
      "Public key for epel-release-latest-9.noarchabc.rpm is not installed\nError: GPG check FAILED\n") do
      rpm = PluginSpecHelper.tmp_path("epel-release-latest-9.noarch.rpm")
      File.write(rpm, "")
      result = PluginSpecHelper.run("dnf",
        {"name" => rpm, "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["msg"].as_s.must_equal(
        "Failed to validate GPG signature for epel-release-9-11.el9.noarch: Public key for epel-release-latest-9.noarchabc.rpm is not installed")
    end
  end

  it "produces the same shape from package: (use: dnf)" do
    with_failing_dnf_shim(MISSING_PKG_STDOUT, MISSING_PKG_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "redhat-lsb-core", "state" => "present", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package redhat-lsb-core available."])
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(5).must_equal(["msg", "failures", "results", "rc", "failed"])
    end
  end

  it "reports ansible's depsolve shape from package: (issue 216)" do
    with_failing_dnf_shim("", DEPSOLVE_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "perl-File-Temp", "state" => "present", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(DEPSOLVE_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "leaves the failures key out of a bare depsolve error (issue 989)" do
    # Ansible-core 2.21's dnf module wrapper forwards `failures` to
    # fail_json only when the backend script's list is non-empty, so a
    # depsolve error that never marks a spec unresolvable fails with
    # msg/results/rc and NO failures key at all (live-confirmed on
    # Rocky 9: `package: name=curl` with curl-minimal installed).
    with_failing_dnf_shim("", DEPSOLVE_STDERR) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "curl", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(DEPSOLVE_MSG)
      result.as_h.has_key?("failures").must_equal(false)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "leaves the failures key out of package:'s bare depsolve error (issue 989)" do
    with_failing_dnf_shim("", DEPSOLVE_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "curl", "state" => "present", "use" => "dnf"})

      result["msg"].as_s.must_equal(DEPSOLVE_MSG)
      result.as_h.has_key?("failures").must_equal(false)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "produces the same shape from package: state latest (issue 114)" do
    # Real ansible fails `state: latest` for a missing package like
    # `state: present` (msg "Failed to install some of the specified
    # packages", failures ["No package libpng12 available."], rc 1);
    # reporting changed: true for a failed dnf/yum transaction is a
    # divergence, not a mere wording gap.
    with_failing_dnf_shim(MISSING_PKG_STDOUT, MISSING_PKG_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "libpng12", "state" => "latest", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package redhat-lsb-core available."])
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(5).must_equal(["msg", "failures", "results", "rc", "failed"])
    end
  end
end

describe "DnfInstallFailures parser - requested expansion (issue 213)" do
  it "expands one entry per requested occurrence when requested is given" do
    stdout = "No match for argument: bison-devel\nNo match for argument: libmcrypt-devel\nNo match for argument: libmcrypt\nNo match for argument: re2c\n"
    stderr = "Error: Unable to find a match: bison-devel libmcrypt-devel libmcrypt re2c libmcrypt-devel\n"

    DnfFailuresParseHarness.new.parse_dnf_install_failures(stdout, stderr,
      ["bison-devel", "libmcrypt-devel", "libmcrypt", "re2c", "libmcrypt-devel"]).must_equal(
      ["No package bison-devel available.",
       "No package libmcrypt-devel available.",
       "No package libmcrypt available.",
       "No package re2c available.",
       "No package libmcrypt-devel available."])
  end

  it "still dedupes when requested is nil" do
    stdout = "No match for argument: foo\nNo match for argument: bar\n"
    stderr = "Error: Unable to find a match: foo bar\n"

    DnfFailuresParseHarness.new.parse_dnf_install_failures(stdout, stderr).must_equal(
      ["No package foo available.", "No package bar available."])
  end

  it "trails parsed entries missing from the requested list in parse order" do
    stdout = "All matches were filtered out by modular filtering for argument: mysql-devel\n"
    stderr = "Error: All matches for argument: mysql-devel were filtered out by modular filtering\n"

    DnfFailuresParseHarness.new.parse_dnf_install_failures(stdout, stderr, ["other-pkg"]).must_equal(
      ["mysql-devel All matches were filtered out by modular filtering for argument: mysql-devel"])
  end
end

describe "DnfInstallFailures depsolve_failure_msg (issue 216)" do
  it "lifts the whole 'Problem:' block as ansible's Depsolve Error msg" do
    DnfFailuresParseHarness.new.depsolve_failure_msg(DEPSOLVE_STDERR).must_equal(DEPSOLVE_MSG)
  end

  it "returns nil for outputs nothing depsolve-shaped" do
    DnfFailuresParseHarness.new.depsolve_failure_msg("No match for argument: foo\n").must_be_nil
    DnfFailuresParseHarness.new.depsolve_failure_msg("").must_be_nil
  end

  it "stops at the first block when a later Problem block follows (dnf+yum compound output)" do
    third_block = DEPSOLVE_STDERR + "Problem: package another-1.0.noarch from appstream is filtered out\n(try to add '--allowerasing')\n"
    DnfFailuresParseHarness.new.depsolve_failure_msg(third_block).must_equal(DEPSOLVE_MSG)
  end
end

# Issue #267 (Rocky, `package: name=cfssl-1.3.2 state=installed` with a
# yum repo whose repodata/repomd.xml 404s): real ansible's dnf module
# reports a metadata-download failure as JUST libdnf's own error text -
# the "Failed to download metadata for repo" summary line with dnf's
# "Error: " prefix stripped - with results [], rc 1 and NO stderr
# (previously the raw dnf stderr became msg + a stderr key) and NO
# failures list. Same shape from both shell-out paths, like the
# depsolve catch: `package:`'s own dnf/yum compound and the dnf/yum
# plugins' shared install batch.
METADATA_404_MSG    = "Failed to download metadata for repo 'cfssl': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried"
METADATA_404_STDERR = "Errors during downloading metadata for repository 'cfssl':\n  - Status code: 404 for https://dl.bintray.com/jumperfly/yum/cfssl/stable/repodata/repomd.xml (IP: 3.95.117.170)\n" +
                      "Error: " + METADATA_404_MSG + "\n"

describe "dnf/yum repo-metadata download failure - ansible's bare msg shape (issue 267)" do
  serial!

  it "reports just libdnf's metadata text from package: state installed" do
    with_failing_dnf_shim("", METADATA_404_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "cfssl-1.3.2", "state" => "installed", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(METADATA_404_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.has_key?("failures").must_equal(false)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "reports the same shape from the dnf plugin's install path" do
    with_failing_dnf_shim("", METADATA_404_STDERR) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "cfssl-1.3.2", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal(METADATA_404_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.has_key?("failures").must_equal(false)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "reports rc 1 from a failing update_cache-only refresh (issue 301)" do
    with_failing_dnf_shim("", METADATA_404_STDERR) do
      result = PluginSpecHelper.run("yum",
        {"name" => "[]", "update_cache" => "true", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal(METADATA_404_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "reports one bare msg when the dnf||yum compound prints the line twice" do
    # The compound prints its own copy per package-manager binary; the
    # reported msg keeps only the first (the task's own dnf attempt).
    DnfFailuresParseHarness.new.repo_metadata_failure_msg(METADATA_404_STDERR * 2).must_equal(METADATA_404_MSG)
  end
end

describe "DnfInstallFailures repo_metadata_failure_msg (issue 267)" do
  it "strips dnf's Error: prefix from the summary line" do
    DnfFailuresParseHarness.new.repo_metadata_failure_msg(METADATA_404_STDERR).must_equal(METADATA_404_MSG)
  end

  it "returns nil for outputs without the metadata-download line" do
    DnfFailuresParseHarness.new.repo_metadata_failure_msg(MISSING_PKG_STDOUT + MISSING_PKG_STDERR).must_be_nil
    DnfFailuresParseHarness.new.repo_metadata_failure_msg("").must_be_nil
  end
end

# Issue #321 (Rocky 9, `package: name: [libunwind, lttng-ust, libcurl]`
# where libunwind doesn't exist and libcurl conflicts with the installed
# libcurl-minimal): real's dnf module marks the missing spec into its
# failures list FIRST and then STILL depsolves the survivors, so the
# task fails with the depsolve msg AND the missing-spec failures (key
# order changed failures msg rc results failed) - while the CLI aborts
# at the missing spec and only ever says "Error: Unable to find a
# match". krikri hunts the Problem block out by re-running the stricken
# specs with --assumeno (no package can land, the re-resolution still
# prints the block); --setopt=strict=0 / --skip-broken would suppress
# it, which is exactly what ansible's depsolve catch reports as msg.
MISSING_MULTI_STDOUT_321 = "No match for argument: libunwind\n"
MISSING_MULTI_STDERR_321 = "Error: Unable to find a match: libunwind\n"
# The retry stage's first-Problem - the (try to add ...) hint outside
# what depsolve_failure_msg lifts into the msg, like the live output.
DEPSOLVE_PROBLEM_LINE_321 = " Problem: package libcurl-8.0.1-51.el9.x86_64 from appstream conflicts with libcurl-minimal-8.0.1-51.el9.x86_64 provided by libcurl-minimal-8.0.1-51.el9.x86_64"
DEPSOLVE_RETRY_STDERR_321 = "Error: \n" + DEPSOLVE_PROBLEM_LINE_321 +
                            "\n" +
                            "(try to add '--allowerasing' to replace conflicting packages or '--skip-broken' to skip uninstallable packages or '--nobest' to use not only best candidate packages)\n"
DEPSOLVE_MSG_321 = "Depsolve Error occurred: \n" + DEPSOLVE_PROBLEM_LINE_321

# The shim's stage switch keys on the real command shape, so a retry
# that forgets either half of the change (the stripped spec list OR the
# --assumeno flag) falls to the default branch and cannot reach the
# Problem block. Anything matching neither pattern runs like the first
# attempt (the probes and the -y retries of the first compound).
private def dnf_shim_stage_lines(stdout : String, stderr : String) : String
  lines = "cat <<'KRIKRI_FAKE_DNF_EOF'\n#{stdout}KRIKRI_FAKE_DNF_EOF\n"
  lines += stderr.lines.map { |line| "echo '#{line.gsub("'", "'\\''")}' >&2" }.join("\n") + "\n" unless stderr.empty?
  lines
end

private def with_two_stage_dnf_shim(match : String, first_stdout : String, first_stderr : String, retry_stdout : String, retry_stderr : String, &)
  shim_dir = PluginSpecHelper.tmp_path("fake-dnf-two-stage")
  Dir.mkdir_p(shim_dir)
  script = "#!/bin/sh\ncase \"$*\" in\n" +
           "*#{match}*)\n#{dnf_shim_stage_lines(first_stdout, first_stderr)};;\n" +
           "*--assumeno*)\n#{dnf_shim_stage_lines(retry_stdout, retry_stderr)};;\n" +
           "*)\n#{dnf_shim_stage_lines(first_stdout, first_stderr)};;\n" +
           "esac\nexit 1\n"
  File.write("#{shim_dir}/dnf", script)
  File.chmod("#{shim_dir}/dnf", 0o755)
  File.write("#{shim_dir}/yum", script)
  File.chmod("#{shim_dir}/yum", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "dnf missing-spec + depsolve - ansible's combined depsolve shape (issue 321)" do
  serial!

  it "reports the depsolve msg with the missing-spec failures from package:" do
    with_two_stage_dnf_shim("libunwind", MISSING_MULTI_STDOUT_321, MISSING_MULTI_STDERR_321, "", DEPSOLVE_RETRY_STDERR_321) do
      result = PluginSpecHelper.run("package",
        {"name" => "libunwind, lttng-ust, libcurl", "state" => "present", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(DEPSOLVE_MSG_321)
      result["failures"].as_a.map(&.as_s).must_equal(["No package libunwind available."])
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(6).must_equal(["changed", "failures", "msg", "rc", "results", "failed"])
    end
  end

  it "reports the same combined shape from the dnf plugin's install batch" do
    with_two_stage_dnf_shim("libunwind", MISSING_MULTI_STDOUT_321, MISSING_MULTI_STDERR_321, "", DEPSOLVE_RETRY_STDERR_321) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "libunwind, lttng-ust, libcurl", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(DEPSOLVE_MSG_321)
      result["failures"].as_a.map(&.as_s).must_equal(["No package libunwind available."])
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(6).must_equal(["changed", "failures", "msg", "rc", "results", "failed"])
    end
  end

  it "keeps the canned install-failure shape when the survivors re-resolve clean" do
    with_two_stage_dnf_shim("libunwind", MISSING_MULTI_STDOUT_321, MISSING_MULTI_STDERR_321,
      "Last metadata expiration check: 0:00:01 ago on Fri Oct 24 00:00:00 2026.\n", "Operation aborted.\n") do
      result = PluginSpecHelper.run("package",
        {"name" => "libunwind, lttng-ust, libcurl", "state" => "present", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package libunwind available."])
      result["rc"].as_i.must_equal(1)
      result.as_h.keys.first(5).must_equal(["msg", "failures", "results", "rc", "failed"])
    end
  end
end

describe "DnfInstallFailures missing-spec stripping (issue 321)" do
  it "collects specs only from the missing-package wording, deduped" do
    DnfFailuresParseHarness.new.missing_specs_from_failures([
      "No package libunwind available.",
      "mysql-devel All matches were filtered out by modular filtering for argument: mysql-devel",
      "No package lttng-ust available.",
      "No package libunwind available.",
    ]).must_equal(["libunwind", "lttng-ust"])
  end

  it "strips missing specs from a batch, keeping modular-filtering specs" do
    DnfFailuresParseHarness.new.specs_without_missing(
      ["libunwind", "mysql-devel", "lttng-ust", "libcurl"],
      ["No package libunwind available."]).must_equal(["mysql-devel", "lttng-ust", "libcurl"])
  end

  it "returns the batch untouched when no missing-spec entry matched" do
    harness = DnfFailuresParseHarness.new
    harness.specs_without_missing(
      ["libcurl"],
      ["mysql-devel All matches were filtered out by modular filtering for argument: mysql-devel"]).must_equal(["libcurl"])
    harness.specs_without_missing(["libcurl"], [] of String).must_equal(["libcurl"])
  end
end

# Issues #769/#932 (Rocky 10, `cacheonly: true` + stale package cache): the
# transaction resolves fine, then base.download_packages()' cache
# verification (dnf/base.py _select_remote_pkgs) raises a plain
# dnf.exceptions.Error - not a DownloadError. Since ansible-core 2.21 the
# module is a wrapper around an embedded script (_embed/dnf.py) that only
# catches DownloadError around the download and only catches
# dnf.exceptions.Error around resolve(), so this one escapes to the
# script's blanket `except Exception`: msg is the bare exception text (no
# "Unknown Error occurred: " prefix), results [], rc 1, and the empty
# `failures` list the script reports is never forwarded by the module
# wrapper - the fatal carries no failures key at all (issue #932,
# live-verified on rockylinux:10 with ansible-core 2.21.6). The CLI prints
# the same failure as log lines - captured live from rockylinux:10's
# `dnf -y update --cacheonly ... gzip`:
CACHEONLY_INVALID_CACHE_STDERR = "Error opening /var/cache/dnf/baseos-5b8a90704d474d3e/packages/gzip-1.13-4.el10_2.x86_64.rpm: No such file or directory\n" \
                                 "Package \"gzip-1.13-4.el10_2.x86_64\" from repository \"baseos\" has incorrect checksum\n" \
                                 "Error: Some packages have invalid cache, but cannot be downloaded due to \"--cacheonly\" option\n"
CACHEONLY_INVALID_CACHE_MSG = "Some packages have invalid cache, but cannot be downloaded due to \"--cacheonly\" option"

# An args-aware shim pair: the `rpm` script answers the installed?-
# precheck (argv0 is rpm itself, so no name check), the `dnf` script's
# `--available` branch answers the not-installed fallback probe, and the
# actual transaction replays the captured failure.
private def with_cacheonly_dnf_shim(installed : Bool, &)
  shim_dir = PluginSpecHelper.tmp_path("fake-dnf-cacheonly")
  Dir.mkdir_p(shim_dir)
  rpm_script = "#!/bin/sh\n"
  rpm_script += "case \"$*\" in *--whatprovides*) exit 1;; esac\n"
  # The installed?-precheck is one batched `rpm -q --qf` for the whole
  # package list (issue #904), so an "installed" answer has to come back
  # as the NEVRA that query would print, not as a bare exit status.
  rpm_script += installed ? "case \"$*\" in *--qf*) printf 'gzip-1.13-4.el10_2.x86_64'; exit 0;; esac\nexit 0\n" : "exit 1\n"
  File.write("#{shim_dir}/rpm", rpm_script)
  File.chmod("#{shim_dir}/rpm", 0o755)
  dnf_script = "#!/bin/sh\ncase \"$*\" in\n  *--available*) exit 0;;\n  *list*) exit 1;;\nesac\n"
  dnf_script += dnf_shim_stage_lines("", CACHEONLY_INVALID_CACHE_STDERR)
  dnf_script += "exit 1\n"
  File.write("#{shim_dir}/dnf", dnf_script)
  File.chmod("#{shim_dir}/dnf", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "dnf cacheonly download failure - ansible's blanket-handler shape (issues 769, 932)" do
  serial!

  it "reports the bare download error with no failures key for an update_only transaction" do
    with_cacheonly_dnf_shim(installed: true) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "gzip", "state" => "present", "update_only" => "true", "cacheonly" => "true",
         "exclude" => "[\"hodypf\", \"ziqoek\", \"zycppc\"]", "security" => "false"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(CACHEONLY_INVALID_CACHE_MSG)
      result.as_h.has_key?("failures").must_equal(false)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(4).must_equal(["msg", "results", "rc", "failed"])
    end
  end

  it "reports the same shape from the install batch (package not in cache)" do
    with_cacheonly_dnf_shim(installed: false) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "gzip", "state" => "present", "cacheonly" => "true"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(CACHEONLY_INVALID_CACHE_MSG)
      result.as_h.has_key?("failures").must_equal(false)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(4).must_equal(["msg", "results", "rc", "failed"])
    end
  end

  # The issue #932 playbook: `state: latest`, `update_only` and
  # `cacheonly` against an installed package, with the chaos mutations
  # around it (best/bugfix/security/exclude/lock_timeout) - the same
  # blanket-handler fatal, msg unprefixed and no `failures` key.
  it "reports the issue 932 state-latest parameter set the same way" do
    with_cacheonly_dnf_shim(installed: true) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "gzip", "state" => "latest", "update_only" => "true", "cacheonly" => "true",
         "best" => "false", "bugfix" => "false", "security" => "false",
         "exclude" => "[\"ehswcf\", \"qfrvxt\"]", "lock_timeout" => "84"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(CACHEONLY_INVALID_CACHE_MSG)
      result.as_h.has_key?("failures").must_equal(false)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
    end
  end
end

# Issue #1050 (kurron.resilio-sync, Rocky 9 --check): ansible's dnf module
# resolves the transaction BEFORE its check-mode stop (dnf.py's
# base.resolve()), so a solver-unsatisfiable goal fails the task with the
# Depsolve Error block under --check exactly like the real install - this
# engine's check-mode branches reported the would-install shape without
# ever running that resolution (check mode ended changed, rc 0, where
# real ended failed). Same shimmed dnf as the real-run tests above; the
# "Operation aborted." twin is what the --assumeno probe gets for a
# SOLVABLE goal (it aborts before downloading or installing anything),
# which must stay a clean would-install.
describe "dnf check-mode resolution probe (issue 1050)" do
  serial!

  it "check mode on a solver-unsatisfiable install fails with the depsolve shape, not changed" do
    with_failing_dnf_shim("", DEPSOLVE_STDERR) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "curl", "state" => "present", "_ansible_check_mode" => "true"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(DEPSOLVE_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "check mode on a solvable install keeps the would-install shape when the probe aborts" do
    with_failing_dnf_shim("", "Operation aborted.\n") do
      result = PluginSpecHelper.run("dnf",
        {"name" => "curl", "state" => "present", "_ansible_check_mode" => "true"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"]?.try(&.as_bool).must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Installed: curl"])
      result["rc"].as_i.must_equal(0)
    end
  end
end

# Issue #1031 (aaditya2801.k8s_master, Rocky --check): ansible's dnf
# module builds its dnf Base and fill_sack()s EVERY enabled repo before
# it resolves anything at all, so a repo whose repomd.xml cannot be
# downloaded fails the task with libdnf's bare metadata msg whatever the
# request was - state: absent, a nameless invocation, `list:`, in
# --check too. This engine formed those verdicts from probes that never
# load the repo metadata (`rpm -q`, a `dnf remove` that resolves from
# the installed set alone), so check mode reported per-spec failed/ok
# where ansible failed on the metadata for every item. The cases below
# pin the metadata shape for exactly those invocation-less verdicts; the
# issue's own `package:` loop shape is pinned in
# package_dnf_check_mode_test.cr.
describe "dnf-family fill_sack metadata load preempts every verdict (issue 1031)" do
  serial!

  it "check mode state: absent fails with the metadata shape instead of a would-remove plan" do
    with_failing_dnf_shim("", METADATA_404_STDERR) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "cfssl-1.3.2", "state" => "absent", "_ansible_check_mode" => "true"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(METADATA_404_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("failures").must_equal(false)
      result.as_h.keys.first(5).must_equal(["changed", "msg", "rc", "results", "failed"])
    end
  end

  it "a real state: absent fails with the metadata shape before any removal can run" do
    # `dnf remove` resolves from the installed set alone and would even
    # remove where ansible's fill_sack() already failed the task - the
    # metadata load has to come first in a real run too.
    with_failing_dnf_shim("", METADATA_404_STDERR) do
      result = PluginSpecHelper.run("dnf",
        {"name" => "cfssl-1.3.2", "state" => "absent"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(METADATA_404_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
    end
  end

  it "a nameless invocation fails with the metadata shape instead of an early verdict" do
    with_failing_dnf_shim("", METADATA_404_STDERR) do
      result = PluginSpecHelper.run("dnf",
        {"state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(METADATA_404_MSG)
      result["rc"].as_i.must_equal(1)
    end
  end

  it "list: reports the metadata shape instead of an empty/raw listing failure" do
    with_failing_dnf_shim("", METADATA_404_STDERR) do
      result = PluginSpecHelper.run("dnf",
        {"list" => "installed"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(METADATA_404_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
    end
  end

  it "package:'s state: absent fails with the same shape" do
    with_failing_dnf_shim("", METADATA_404_STDERR) do
      result = PluginSpecHelper.run("package",
        {"name" => "cfssl-1.3.2", "state" => "absent", "use" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(METADATA_404_MSG)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
    end
  end
end

# Issue #1055 (officel.mysql56, check phase): under --check this engine
# reported "changed" for the role's `yum: name: mysql-community-server`
# where real ansible fatal'd. Ansible's dnf module marks every spec and
# resolves the transaction BEFORE its check-mode stop (it stops only
# before do_transaction), so a package the repos cannot name fails the
# task in check mode with the very shape the real install reports:
#   fatal: [testhost]: FAILED! => {"changed": false, "failures": ["No
#   package mysql-community-server available."], "msg": "Failed to
#   install some of the specified packages", "rc": 1, "results": []}
# Live-verified against ansible-core 2.21.6 on a Rocky 9 target with the
# role's own enablerepo globs (which match no repo there either - real's
# dnf backend warns and continues past them, so the failure is the
# missing package). The check-mode resolution probe above fails this
# case through the same parsers the real install uses; these pin its
# exact shape.
#
# dnf/rpm are not on the spec host; everything runs against shimmed
# binaries on PATH via the plugin's _environment (same method as the
# issue-781/1019 tests) - no process-wide ENV mutation, so no serial!.
# The dnf shim logs every invocation so the tests can prove check mode
# RESOLVES the transaction (the --assumeno probe) instead of guessing
# "changed", and it answers a resolvable probe with real dnf's own
# abort shape ("Operation aborted.", exit 1) - which must not read as a
# failure.
private def with_dnf1055_shims(install_mode : String, available : Array(String), &)
  bin_dir = File.join(Dir.tempdir, "krikri-dnf1055-#{Random.rand(1_000_000)}")
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

  dnf_shim = <<-'SH'
    #!/bin/sh
    printf '%s\n' "$*" >> "${KRIKRI_DNF_LOG:?}"
    case "$2/$3" in
      "list/--available")
        for pair in ${KRIKRI_DNF_AVAILABLE:-}; do
          pkg="${pair%%=*}"; evr="${pair#*=}"
          [ "$4" = "$pkg" ] && { printf 'Available Packages\n%s.x86_64 %s fakerepo\n' "$pkg" "$evr"; exit 0; }
        done
        exit 1
        ;;
    esac
    for arg in "$@"; do
      case "$arg" in
        --enablerepo=*)
          echo "Error: Unknown repo: '${arg#--enablerepo=}'" >&2
          exit 1
          ;;
      esac
    done
    case "$1" in
      install)
        case "${KRIKRI_DNF_INSTALL_MODE:-missing}" in
          missing)
            echo "No match for argument: mysql-community-server"
            echo "Error: Unable to find a match: mysql-community-server" >&2
            exit 1
            ;;
          aborted)
            echo "Operation aborted."
            exit 1
            ;;
        esac
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
    "PATH"                    => "#{bin_dir}:/usr/bin:/bin",
    "KRIKRI_DNF_LOG"          => log,
    "KRIKRI_DNF_INSTALL_MODE" => install_mode,
    "KRIKRI_DNF_AVAILABLE"    => available.join(" "),
    "KRIKRI_RPM_INSTALLED"    => "",
    "KRIKRI_RPM_FILE_NEVRA"   => "tree-1.8.0-10.el9.x86_64",
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(bin_dir) if bin_dir
end

describe "dnf/yum check mode - an unresolvable spec fails like the real install (issue 1055)" do
  it "check mode fails a missing package with the install-failure shape, like real ansible" do
    with_dnf1055_shims("missing", [] of String) do |env, log|
      result = PluginSpecHelper.run("yum", {
        "name"                => "mysql-community-server",
        "state"               => "present",
        "enablerepo"          => "mysql-community*,mysql-tools*,mysql56*",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      }, vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package mysql-community-server available."])
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.keys.first(5).must_equal(["msg", "failures", "results", "rc", "failed"])
      # The verdict comes from RESOLVING, not from a guess - the probe
      # ran its marks/resolve pass before the failure was known.
      calls = File.exists?(log) ? File.read(log) : ""
      calls.includes?("--assumeno").must_equal(true)
    end
  end

  it "state latest fails a missing package in check mode the same way" do
    with_dnf1055_shims("missing", [] of String) do |env, _|
      result = PluginSpecHelper.run("dnf", {
        "name"                => "mysql-community-server",
        "state"               => "latest",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      }, vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Failed to install some of the specified packages")
      result["failures"].as_a.map(&.as_s).must_equal(["No package mysql-community-server available."])
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
    end
  end

  it "a resolvable spec keeps the would-install shape - the probe's abort is not a failure" do
    with_dnf1055_shims("aborted", ["chrony=4.8-1.el9"]) do |env, log|
      result = PluginSpecHelper.run("dnf", {
        "name"                => "chrony",
        "state"               => "present",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      }, vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"]?.try(&.as_bool?).must_be_nil
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Installed: chrony-4.8-1.el9.x86_64"])
      result["rc"].as_i.must_equal(0)
      calls = File.exists?(log) ? File.read(log) : ""
      calls.includes?("--assumeno").must_equal(true)
    end
  end
end
