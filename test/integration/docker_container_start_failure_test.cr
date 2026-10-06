require "../minitest_helper"

# docker_container's container START-failure parity: real's container_start
# (module_utils/module_container/module.py) catches ANY start exception and
# fails with "Error starting container <id>: <SDK text>" - same for a fresh
# create-and-start as for starting an existing stopped container. Provoke it
# the documented way, a host-port conflict: two containers publishing the
# same host port (the daemon rejects the second start with a 500 whose body
# carries its own bind error, which PluginHelpers::DockerSdkError renders as
# the SDK's APIError text).
#
# Byte-verified against ansible-core 2.19.11 + community.docker 5.2.1 on a
# podman docker-compatible socket (real's registered failure is exactly
# {"failed", "msg", "changed", "exception"} with
# "Error starting container <id>: 500 Server Error for
# http+docker://localhost/v1.41/containers/<id>/start: Internal Server
# Error (\"<daemon bind error>\")" - only the container id differs run to
# run, on both engines).
#
# The socket is a podman `system service` endpoint
# (`podman system service --time=0 unix:///tmp/krikri-kp-dk.sock`); the
# specs skip when it is not up. Everything here is scoped to the
# krikri-kp-dk-start- name prefix and removed again.
DOCKER_START_SOCKET      = "unix:///tmp/krikri-kp-dk.sock"
DOCKER_START_SOCKET_PATH = "/tmp/krikri-kp-dk.sock"

# Uncommon high port so a concurrent suite/daemon cannot hold it.
DOCKER_START_PORT = "18987"

def docker_start_params(name : String, extra : Hash(String, String) = {} of String => String) : Hash(String, String)
  {
    "name"        => name,
    "image"       => "docker.io/library/busybox:latest",
    "command"     => %(["sleep", "300"]),
    "ports"       => "#{DOCKER_START_PORT}:80",
    "state"       => "started",
    "docker_host" => DOCKER_START_SOCKET,
  }.merge(extra)
end

def docker_start_socket? : Bool
  File.exists?(DOCKER_START_SOCKET_PATH)
end

def docker_start_cleanup(name : String) : Nil
  PluginSpecHelper.run("docker_container", {"name" => name, "state" => "absent", "docker_host" => DOCKER_START_SOCKET})
end

describe "docker_container start failure" do
  serial!

  it "reports a fresh create-and-start failure with real's Error starting container wording" do
    skip("no Docker-API socket at #{DOCKER_START_SOCKET_PATH}") unless docker_start_socket?

    first = PluginSpecHelper.run("docker_container", docker_start_params("krikri-kp-dk-start-first"))
    first["changed"].as_bool.must_equal(true)

    second = PluginSpecHelper.run("docker_container", docker_start_params("krikri-kp-dk-start-second"))
    docker_start_cleanup("krikri-kp-dk-start-first")
    docker_start_cleanup("krikri-kp-dk-start-second")

    second["failed"].as_bool.must_equal(true)
    second.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
    second["changed"].as_bool.must_equal(false)

    msg = second["msg"].as_s
    # "Error starting container <id>: 500 Server Error for
    # http+docker://localhost/v1.41/containers/<id>/start: Internal Server
    # Error (\"<daemon bind error>\")" - the id is the created container's.
    msg.must_match(/\AError starting container [0-9a-f]{64}: 500 Server Error for http\+docker:\/\/localhost\/v1\.41\/containers\/[0-9a-f]{64}\/start: Internal Server Error \(".*address already in use"\)\z/)
    # The failed create leaves the container behind unstarted - absent
    # cleanup above removes both.
  end

  it "reports starting an existing stopped container with the same wording" do
    skip("no Docker-API socket at #{DOCKER_START_SOCKET_PATH}") unless docker_start_socket?

    name = "krikri-kp-dk-start-existing"
    PluginSpecHelper.run("docker_container", docker_start_params(name))
    # Steal the port from underneath the plugin: stop the running
    # container, start a squatter on the same host port, then ask the
    # plugin to start the (stopped) first container again.
    PluginSpecHelper.run("docker_container", {"name" => name, "state" => "stopped", "docker_host" => DOCKER_START_SOCKET})
    squatter = PluginSpecHelper.run("docker_container", docker_start_params("krikri-kp-dk-start-squatter"))
    squatter["changed"].as_bool.must_equal(true)

    result = PluginSpecHelper.run("docker_container", docker_start_params(name))
    docker_start_cleanup(name)
    docker_start_cleanup("krikri-kp-dk-start-squatter")

    result["failed"].as_bool.must_equal(true)
    msg = result["msg"].as_s
    msg.must_match(/\AError starting container [0-9a-f]{64}: 500 Server Error for http\+docker:\/\/localhost\/v1\.41\/containers\/[0-9a-f]{64}\/start: Internal Server Error \(".*address already in use"\)\z/)
  end
end
