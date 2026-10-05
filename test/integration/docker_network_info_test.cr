require "../minitest_helper"

# community.docker.docker_network_info - previously an unimplemented
# collection module: the task silently SKIPPED at parse time, leaving a
# registered result without `exists:`, so the next task's
# `when: not result.exists` hard-errored with "object of type 'dict' has
# no attribute 'exists'" (tigattack.frigate_docker, round 73280).
# Ansible's docker modules FAIL the task with a connection error when the
# daemon is unreachable - they never skip.
#
# The daemon-unreachable spec needs no docker daemon (deliberately
# unreachable socket); the found/not-found specs need a real one and skip
# otherwise (the same convention as the other daemon-dependent plugins).
describe "docker_network_info plugin" do
  it "fails when name is missing" do
    result = PluginSpecHelper.run("docker_network_info", {} of String => String)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("missing required arguments: name")
  end

  it "fails with a connection error (never skips) when the Docker daemon is unreachable" do
    result = PluginSpecHelper.run("docker_network_info", {
      "name"        => "krikri-spec-unreachable",
      "docker_host" => "unix:///nonexistent/krikri-no-such-#{Process.pid}.sock",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Error connecting")
    result["msg"].as_s.must_include("Cannot connect to the Docker daemon")
  end

  it "returns exists: false (not failed) when the daemon is reachable but the network is absent" do
    # Probe with the plugin itself against the same default connection
    # (docker_host: params, DOCKER_HOST env, default socket) - `docker
    # network ls` via the CLI can succeed through a context or a
    # different socket than the one the Engine-API connection here uses.
    probe = PluginSpecHelper.run("docker_network_info", {"name" => "krikri-probe-#{Process.pid}"})
    skip("no reachable docker daemon") if probe["msg"]?.try(&.as_s).to_s.includes?("Error connecting")

    result = PluginSpecHelper.run("docker_network_info", {
      "name" => "krikri-spec-definitely-absent-#{Process.pid}",
    })
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["exists"].as_bool.must_equal(false)
    result["network"].as_nil.must_be_nil
  end
end
