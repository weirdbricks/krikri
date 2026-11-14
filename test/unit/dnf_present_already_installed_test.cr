require "../minitest_helper"
require "file_utils"
require "json"

# Issue #1019 (aaditya2801.k8s_master): `package: {name: <plain name>,
# state: present}` on an ALREADY-INSTALLED name used to report ok without
# ever invoking dnf. Ansible's dnf module builds its dnf Base and
# fill_sack()s every enabled repo before it resolves anything, so a repo
# whose repomd.xml cannot be downloaded fails the task with libdnf's bare
# metadata msg even though the resolution itself comes out empty - in
# --check too (dnf.py resolves first and only stops before
# do_transaction). Live-verified against ansible-core 2.21 on Rocky 10
# with the role's own dead kubernetes repo file in place: real fatal'd on
# the already-installed iproute-tc with {"changed": false, "msg":
# "Failed to download metadata for repo 'kubernetes': Cannot download
# repomd.xml: Cannot download repodata/repomd.xml: All mirrors were
# tried", "rc": 1, "results": []}, also under --check, while this engine
# said ok in both modes without ever running dnf.
#
# dnf/rpm are not on the spec host; everything runs against shimmed
# binaries on PATH via the plugin's _environment (same method as the
# issue-781/813 tests) - no process-wide ENV mutation, so no serial!.
# The dnf shim logs every invocation so the "still runs dnf" test can
# prove the early ok is gone, not just that the answer changed.
private def with_dnf1019_shims(metadata_failure : Bool, &)
  bin_dir = File.join(Dir.tempdir, "krikri-dnf1019-#{Random.rand(1_000_000)}")
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

  dnf_shim = <<-SH
    #!/bin/sh
    printf '%s\n' "$*" >> "${KRIKRI_DNF_LOG:?}"
    if [ "${KRIKRI_DNF_METADATA_FAILURE:-0}" = "1" ]; then
      echo "Errors during downloading metadata for repository 'badrepo':" >&2
      echo "  - Curl error (37): Couldn't read a file:// file for file:///nonexistent/repo/repodata/repomd.xml" >&2
      echo "Error: Failed to download metadata for repo 'badrepo': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried" >&2
      exit 1
    fi
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
    "KRIKRI_RPM_FILE_NEVRA"       => "tree-1.8.0-10.el9.x86_64",
    "KRIKRI_RPM_INSTALLED"        => "tree=tree-1.8.0-10.el9.x86_64",
    "KRIKRI_DNF_METADATA_FAILURE" => metadata_failure ? "1" : "0",
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(bin_dir) if bin_dir
end

describe "dnf plugin - an already-installed plain name still runs the dnf transaction (issue 1019)" do
  it "a real run on an already-installed plain name fails when repo metadata cannot download" do
    with_dnf1019_shims(true) do |env, _log|
      result = PluginSpecHelper.run("dnf", {
        "name"              => "tree",
        "state"             => "present",
        "disable_gpg_check" => "true",
        "_environment"      => env,
      })
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("failures").must_equal(false)
      result["msg"].as_s.must_equal(
        "Failed to download metadata for repo 'badrepo': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried")
      result["results"].as_a.must_equal([] of JSON::Any)
    end
  end

  it "check mode on an already-installed plain name fails the same way" do
    with_dnf1019_shims(true) do |env, _log|
      result = PluginSpecHelper.run("dnf", {
        "name"                => "tree",
        "state"               => "present",
        "disable_gpg_check"   => "true",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["rc"].as_i.must_equal(1)
      result["msg"].as_s.must_equal(
        "Failed to download metadata for repo 'badrepo': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried")
    end
  end

  it "a real run on an already-installed plain name runs the dnf resolution, and its empty transaction is the no-op ok" do
    with_dnf1019_shims(false) do |env, log|
      result = PluginSpecHelper.run("dnf", {
        "name"              => "tree",
        "state"             => "present",
        "disable_gpg_check" => "true",
        "_environment"      => env,
      })
      result["failed"]?.try(&.as_bool?).must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(0)
      # The whole point of the fix: the metadata load happens by RUNNING
      # the install resolution (dnf.py fill_sack()s before it knows the
      # transaction is empty), so the dnf shim must have been called with
      # an `install` subcommand - the old early ok never invoked it.
      calls = File.exists?(log) ? File.read(log) : ""
      calls.includes?("install").must_equal(true)
    end
  end
end

# The same bug lived in the generic `package:` module's own dnf backend
# (plugins/package.cr's handle_dnf), which the role's task actually uses
# (`package: {name: "{{ item }}", state: present}`): its `is_installed`
# branch returned the "already installed" ok without ever invoking dnf.
# Same shimmed binaries, same expectations - only the success msg
# differs (this module's own wording).
describe "package plugin - an already-installed plain name still runs the dnf transaction (issue 1019)" do
  it "a real run on an already-installed plain name fails when repo metadata cannot download" do
    with_dnf1019_shims(true) do |env, _log|
      result = PluginSpecHelper.run("package", {
        "name"         => "tree",
        "state"        => "present",
        "use"          => "dnf",
        "_environment" => env,
      })
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["rc"].as_i.must_equal(1)
      result.as_h.has_key?("failures").must_equal(false)
      result["msg"].as_s.must_equal(
        "Failed to download metadata for repo 'badrepo': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried")
      result["results"].as_a.must_equal([] of JSON::Any)
    end
  end

  it "check mode on an already-installed plain name fails the same way" do
    with_dnf1019_shims(true) do |env, _log|
      result = PluginSpecHelper.run("package", {
        "name"                => "tree",
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(
        "Failed to download metadata for repo 'badrepo': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried")
    end
  end

  it "a real run on an already-installed plain name runs the dnf resolution, and its empty transaction stays the no-op ok" do
    with_dnf1019_shims(false) do |env, log|
      result = PluginSpecHelper.run("package", {
        "name"         => "tree",
        "state"        => "present",
        "use"          => "dnf",
        "_environment" => env,
      })
      result["failed"]?.try(&.as_bool?).must_be_nil
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      calls = File.exists?(log) ? File.read(log) : ""
      calls.includes?("install").must_equal(true)
    end
  end

  # Issue #1243: `package:` on a dnf host registered only
  # changed/failed/msg for an already-installed name, so a playbook
  # reading out.results died with "object of type 'dict' has no
  # attribute 'results'". Ansible's package action plugin delegates to
  # the dnf module, whose empty transaction exits with its full response
  # dict - live-verified on Rocky 10 (ansible-core 2.21.6): msg "Nothing
  # to do", rc 0, results [].
  it "reports the dnf response shape with rc and results on the already-installed no-op (issue 1243)" do
    with_dnf1019_shims(false) do |env, _log|
      result = PluginSpecHelper.run("package", {
        "name"         => "tree",
        "state"        => "present",
        "use"          => "dnf",
        "_environment" => env,
      })
      result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(0)
    end
  end
end
