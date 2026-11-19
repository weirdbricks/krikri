require "../minitest_helper"

# community.docker.docker_volume - previously an unimplemented collection
# module: a task calling it was dropped at parse time, printed `skipping:`
# for every loop item, and let the play run on to the next task's fatal
# (exit 4) where real runs the module and fails it on the unreachable
# daemon (exit 2). That is lexa-uw.mailserver's "Create volumes for mail
# data" loop under --check, issue #1611 - Ansible's docker modules never
# silently skip, and a skipped task leaves a registered result without
# the module's own keys.
#
# The wire shapes asserted below are Ansible's module-result insertion
# order, live-verified against ansible-core 2.21.6 + community.docker
# 5.2.1: {"changed", "actions", "volume", "diff", "failed"} in
# check_mode/debug, {"changed", "volume", "failed"} for a real present,
# and {"changed", "actions", "failed"} for absent (which never pops
# `actions`).
#
# scripts/minitest.sh unsets DOCKER_HOST, so daemon-dependent specs take
# an explicit socket: KRIKRI_VOLUME_TEST_DOCKER_HOST, else the developer
# shell's DOCKER_HOST when that socket actually exists.
private def docker_volume_test_host : String?
  host = ENV["KRIKRI_VOLUME_TEST_DOCKER_HOST"]? || ENV["DOCKER_HOST"]?
  return nil unless host
  return nil unless host.starts_with?("unix://")
  File.exists?(host.sub("unix://", "")) ? host : nil
end

describe "docker_volume plugin" do
  serial!

  it "fails with a connection error (never skips) when the Docker daemon is unreachable" do
    skip "python requests not importable, the SDK gate would answer first" unless PluginSpecHelper.docker_sdk_importable?
    result = PluginSpecHelper.run("docker_volume", {
      "name"        => "krikri-spec___volume-unreachable",
      "docker_host" => "unix:///nonexistent/krikri-no-such-#{Process.pid}.sock",
    })
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Error connecting: Error while fetching server API version: " \
                                  "('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))")
  end

  # The role under test (and most real roles) spell the module's
  # volume_name argument as `name:`, real's argspec alias. Reaching the
  # connection at all proves the alias resolved: a canonical-only lookup
  # would fail "missing required arguments: volume_name" before it.
  it "resolves the name alias to volume_name before validation" do
    skip "python requests not importable, the SDK gate would answer first" unless PluginSpecHelper.docker_sdk_importable?
    result = PluginSpecHelper.run("docker_volume", {
      "name"        => "krikri-spec___volume-alias",
      "docker_host" => "unix:///nonexistent/krikri-no-such-#{Process.pid}.sock",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Error connecting")
  end

  it "matches Ansible's check_mode create key set and order" do
    host = docker_volume_test_host
    skip("no reachable docker daemon socket") unless host
    name = "krikri-spec___vol-create-#{Process.pid}"
    begin
      result = PluginSpecHelper.run("docker_volume", {
        "name"                => name,
        "docker_host"         => host,
        "_ansible_check_mode" => "true",
      })
      result.as_h.keys.must_equal(["changed", "actions", "volume", "diff", "failed"])
      result["changed"].as_bool.must_equal(true)
      result["failed"].as_bool.must_equal(false)
      result["actions"].as_a.map(&.as_s).must_equal(["Created volume #{name} with driver local"])
      # nothing was actually created, so `volume` is Ansible's null
      result["volume"].raw.must_be_nil
      result["diff"]["differences"].as_a.must_be_empty
    ensure
      PluginSpecHelper.run("docker_volume", {"name" => name, "docker_host" => host, "state" => "absent"})
    end
  end

  it "matches Ansible's real present and removed key sets and order" do
    host = docker_volume_test_host
    skip("no reachable docker daemon socket") unless host
    name = "krikri-spec___vol-removed-#{Process.pid}"
    begin
      created = PluginSpecHelper.run("docker_volume", {"name" => name, "docker_host" => host})
      created.as_h.keys.must_equal(["changed", "volume", "failed"])
      created["changed"].as_bool.must_equal(true)
      created["volume"]["Name"].as_s.must_equal(name)

      removed = PluginSpecHelper.run("docker_volume", {"name" => name, "docker_host" => host, "state" => "absent"})
      removed.as_h.keys.must_equal(["changed", "actions", "failed"])
      removed["changed"].as_bool.must_equal(true)
      removed["actions"].as_a.map(&.as_s).must_equal(["Removed volume #{name}"])
    ensure
      PluginSpecHelper.run("docker_volume", {"name" => name, "docker_host" => host, "state" => "absent"})
    end
  end

  it "matches Ansible's already-absent key set, keeping the empty actions list" do
    host = docker_volume_test_host
    skip("no reachable docker daemon socket") unless host
    result = PluginSpecHelper.run("docker_volume", {
      "name"        => "krikri-spec___vol-missing-#{Process.pid}",
      "docker_host" => host,
      "state"       => "absent",
    })
    result.as_h.keys.must_equal(["changed", "actions", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["actions"].as_a.must_be_empty
  end

  it "matches Ansible's check_mode removal diff (an empty dict without --diff)" do
    host = docker_volume_test_host
    skip("no reachable docker daemon socket") unless host
    name = "krikri-spec___vol-check-remove-#{Process.pid}"
    begin
      PluginSpecHelper.run("docker_volume", {"name" => name, "docker_host" => host})
      result = PluginSpecHelper.run("docker_volume", {
        "name"                => name,
        "docker_host"         => host,
        "state"               => "absent",
        "_ansible_check_mode" => "true",
      })
      result.as_h.keys.must_equal(["changed", "actions", "diff", "failed"])
      result["changed"].as_bool.must_equal(true)
      result["actions"].as_a.map(&.as_s).must_equal(["Removed volume #{name}"])
      # absent() never records `differences`; the tracker's exists entry
      # only shows up under --diff
      result["diff"].as_h.keys.must_equal([] of String)
    ensure
      PluginSpecHelper.run("docker_volume", {"name" => name, "docker_host" => host, "state" => "absent"})
    end
  end

  it "reports recreate=options-changed drift in check_mode with --diff" do
    host = docker_volume_test_host
    skip("no reachable docker daemon socket") unless host
    name = "krikri-spec___vol-drift-#{Process.pid}"
    begin
      PluginSpecHelper.run("docker_volume", {
        "name"        => name,
        "docker_host" => host,
        "labels"      => %({"a": "b"}),
      })
      result = PluginSpecHelper.run("docker_volume", {
        "name"                => name,
        "docker_host"         => host,
        "labels"              => %({"a": "c"}),
        "recreate"            => "options-changed",
        "_ansible_check_mode" => "true",
        "_ansible_diff"       => "true",
      })
      result["changed"].as_bool.must_equal(true)
      result["actions"].as_a.map(&.as_s).must_equal([
        "Removed volume #{name}",
        "Created volume #{name} with driver local",
      ])
      result["diff"]["differences"].as_a.map(&.as_s).must_equal(["labels.a"])
      result["diff"]["before"]["labels.a"].as_s.must_equal("b")
      result["diff"]["after"]["labels.a"].as_s.must_equal("c")
      result["diff"]["before"]["exists"].as_bool.must_equal(true)
      result["diff"]["after"]["exists"].as_bool.must_equal(true)
    ensure
      PluginSpecHelper.run("docker_volume", {"name" => name, "docker_host" => host, "state" => "absent"})
    end
  end

  # sanitize_labels() runs after the client's /version round trip (real
  # builds the client first), so this needs a reachable daemon.
  it "fails a bool label value with real's sanitize_labels wording" do
    host = docker_volume_test_host
    skip("no reachable docker daemon socket") unless host
    result = PluginSpecHelper.run_raw("docker_volume", {
      "name"        => JSON::Any.new("krikri-spec___vol-label-#{Process.pid}"),
      "docker_host" => JSON::Any.new(host),
      "labels"      => JSON::Any.new(%({"a":true})),
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("The value True for 'a' of labels is not a string or something than can be safely converted to a string!")
  end
end
