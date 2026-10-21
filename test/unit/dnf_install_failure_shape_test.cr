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
    with_failing_dnf_shim(
      "Errors during downloading metadata for repo 'baseos':\n",
      "Error: Failed to download metadata for repo 'baseos'\n") do
      result = PluginSpecHelper.run("dnf",
        {"name" => "redhat-lsb-core", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to install packages")
      result["failures"].as_a.map(&.as_s).must_equal(
        ["Error: Failed to download metadata for repo 'baseos'",
         "Errors during downloading metadata for repo 'baseos':"])
    end
  end

  it "reports a module-level GPG validation failure for an unsigned rpm URL (issue 60)" do
    with_failing_dnf_shim(
      "",
      "Public key for epel-release-latest-9.noarchabc.rpm is not installed. Failing package is: epel-release-9-11.el9.noarch\nError: GPG check FAILED\n") do
      result = PluginSpecHelper.run("dnf",
        {"name" => "http://example.invalid/epel-release-latest-9.noarch.rpm", "state" => "present"},
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
      result = PluginSpecHelper.run("dnf",
        {"name" => "http://example.invalid/epel-release-latest-9.noarch.rpm", "state" => "present"},
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
