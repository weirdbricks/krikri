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
# the per-spec failures parser (nothing in it matches those lines).
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
      result.as_h.has_key?("rc").must_equal(false)
      result.as_h.has_key?("results").must_equal(false)
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
      result["failures"].as_a.map(&.as_s).must_equal([] of String)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("stderr").must_equal(false)
      result.as_h.keys.first(6).must_equal(["changed", "failures", "msg", "rc", "results", "failed"])
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
