require "../minitest_helper"

# Per-module daemon-unreachable wording parity: every SDK-based
# community.docker module fails with
#   "Error connecting: Error while fetching server API version: <requests text>"
# (AnsibleDockerClientBase wraps the SDK Client.__init__ failure, whose
# first round trip is GET /version), and the two CLI-based ones
# (docker_image_build, docker_compose_v2) fail at real's
# `docker --host ... version --format '{{ json . }}'` probe with the CLI's
# own stderr in the run_command(check_rc=True) shape instead.
# Byte-verified against community.docker 5.2.1 with DOCKER_HOST pointed at
# a nonexistent socket; needs NO live daemon (the socket must not exist,
# which the specs themselves guarantee by pointing at a path under the
# suite's own scratch space).
#
# The CLI-probe specs DO need the `docker` CLI binary on PATH (they assert
# its own connection failure output) and skip when it is absent - the
# probe's failure text is the CLI's, not the engine's.
DEAD_SOCKET = "/tmp/krikri-no-such-sock"

# The CLI binary real's probe resolves (get_bin_path('docker') in the
# module process == `command -v docker` in the plugin's exec PATH).
def docker_cli_path : String
  `command -v docker`.strip
end

def dead_socket_unreachable(module_name : String, extra : Hash(String, String) = {} of String => String) : JSON::Any
  params = {"docker_host" => "unix://#{DEAD_SOCKET}"}.merge(extra)
  PluginSpecHelper.run(module_name, params)
end

describe "docker modules daemon-unreachable wording" do
  it "docker_container reports the SDK's version-fetch failure" do
    result = dead_socket_unreachable("docker_container",
      {"name" => "krikri-dead-socket-container", "image" => "docker.io/library/busybox:latest", "state" => "started"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error connecting: Error while fetching server API version: " \
                                  "('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))")
  end

  it "docker_image reports the SDK's version-fetch failure" do
    result = dead_socket_unreachable("docker_image",
      {"name" => "docker.io/library/busybox:latest", "source" => "pull", "state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error connecting: Error while fetching server API version: " \
                                  "('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))")
  end

  it "docker_network reports the SDK's version-fetch failure" do
    result = dead_socket_unreachable("docker_network", {"name" => "krikri-dead-socket-network"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error connecting: Error while fetching server API version: " \
                                  "('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))")
  end

  it "docker_login reports the SDK's version-fetch failure" do
    result = dead_socket_unreachable("docker_login",
      {"registry_url" => "https://example.com", "username" => "u", "password" => "p"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error connecting: Error while fetching server API version: " \
                                  "('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))")
  end

  it "docker_network_info reports the SDK's version-fetch failure" do
    result = dead_socket_unreachable("docker_network_info", {"name" => "krikri-dead-socket-network"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error connecting: Error while fetching server API version: " \
                                  "('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))")
  end

  it "docker_image_build fails at real's CLI version probe with the CLI's own output" do
    cli = docker_cli_path
    skip("no docker CLI on PATH - the probe's failure text is the CLI's own") if cli.empty?
    result = dead_socket_unreachable("docker_image_build",
      {"path" => "/tmp", "name" => "krikri-dead-socket-build"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(DEAD_SOCKET)
    result["cmd"].as_s.must_equal("#{cli} --host unix://#{DEAD_SOCKET} version --format '{{ json . }}'")
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.must_include(DEAD_SOCKET)
    result.as_h.keys.must_equal(["cmd", "rc", "stdout", "stderr", "failed", "msg", "stdout_lines", "stderr_lines", "changed", "exception"])
  end

  it "docker_compose_v2 fails at real's CLI version probe with the CLI's own output" do
    cli = docker_cli_path
    skip("no docker CLI on PATH - the probe's failure text is the CLI's own") if cli.empty?
    result = dead_socket_unreachable("docker_compose_v2", {"project_src" => "/tmp"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(DEAD_SOCKET)
    result["cmd"].as_s.must_equal("#{cli} --host unix://#{DEAD_SOCKET} version --format '{{ json . }}'")
    result.as_h.keys.must_equal(["cmd", "rc", "stdout", "stderr", "failed", "msg", "stdout_lines", "stderr_lines", "changed", "exception"])
  end

  it "docker_image_build reports the CLI-missing wording when no docker binary is on PATH" do
    # real's get_bin_path failure - a plain fail_json(msg=...) with no
    # cmd/rc. Provoke it with a PATH that has no docker in it (the plugin
    # process's own PATH is what the probe's resolution runs against).
    result = PluginSpecHelper.run("docker_image_build",
      {"path" => "/tmp", "name" => "krikri-dead-socket-build", "docker_host" => "unix://#{DEAD_SOCKET}"},
      env: {"PATH" => "/tmp/krikri-no-such-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Cannot find docker CLI in path. Please provide it explicitly with the docker_cli parameter")
    result.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
  end
end
