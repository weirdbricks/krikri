require "../minitest_helper"
require "file_utils"
require "json"

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
end
