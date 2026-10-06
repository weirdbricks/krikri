require "../minitest_helper"
require "../../src/krikri/plugin_helpers/docker_sdk_error"
require "../../src/krikri/plugin_helpers/docker_client"

module Krikri
  module PluginHelpers
    # Regression tests for the daemon-unreachable wording real
    # community.docker modules fail with ("Error connecting: Error while
    # fetching server API version: ..." - AnsibleDockerClientBase's
    # wrapper around the SDK Client.__init__ failure, whose first round
    # trip is GET /version). The transport-error text after the prefix is
    # byte-verified against community.docker 5.2.1 driving a podman
    # docker-compatible socket with DOCKER_HOST pointed at a nonexistent
    # socket / a directory path / a permission-denied socket.
    # Pure message construction - no daemon needed.
    describe DockerSdkError do
      describe ".connect_error_text" do
        def connect_error(errno : Errno) : Exception
          Socket::ConnectError.from_os_error("connect", errno)
        end

        it "renders a nonexistent socket path as requests' FileNotFoundError tuple" do
          DockerSdkError.connect_error_text(connect_error(Errno::ENOENT), "unix:///tmp/krikri-no-such-sock")
            .must_equal("Error connecting: Error while fetching server API version: " \
                        "('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))")
        end

        it "renders a refused socket path (e.g. a directory) as requests' ConnectionRefusedError tuple" do
          DockerSdkError.connect_error_text(connect_error(Errno::ECONNREFUSED), "unix:///tmp")
            .must_equal("Error connecting: Error while fetching server API version: " \
                        "('Connection aborted.', ConnectionRefusedError(111, 'Connection refused'))")
        end

        it "renders a permission-denied socket as requests' PermissionError tuple" do
          DockerSdkError.connect_error_text(connect_error(Errno::EACCES), "unix:///run/user/1000/podman/podman.sock")
            .must_equal("Error connecting: Error while fetching server API version: " \
                        "('Connection aborted.', PermissionError(13, 'Permission denied'))")
        end

        it "renders a reset connection as requests' ConnectionResetError tuple" do
          DockerSdkError.connect_error_text(connect_error(Errno::ECONNRESET), "unix:///tmp/krikri-dead.sock")
            .must_equal("Error connecting: Error while fetching server API version: " \
                        "('Connection aborted.', ConnectionResetError(104, 'Connection reset by peer'))")
        end

        it "falls back to requests' OSError repr for an errno requests has no subclass for" do
          DockerSdkError.connect_error_text(connect_error(Errno::ENETUNREACH), "unix:///tmp/krikri-dead.sock")
            .must_equal("Error connecting: Error while fetching server API version: " \
                        "('Connection aborted.', OSError(101, 'Network is unreachable'))")
        end

        it "renders a TCP refusal in urllib3's pool-retry shape (pointer aside - real's is a live heap address)" do
          text = DockerSdkError.connect_error_text(connect_error(Errno::ECONNREFUSED), "tcp://127.0.0.1:1")
          text.must_equal("Error connecting: Error while fetching server API version: " \
                          "HTTPConnectionPool(host='127.0.0.1', port=1): Max retries exceeded with url: /version " \
                          "(Caused by NewConnectionError('<urllib3.connection.HTTPConnection object at #{text[/object at (0x[0-9a-f]+)>/, 1]}>: " \
                          "Failed to establish a new connection: [Errno 111] Connection refused'))")
        end

        it "words an https daemon HTTPSConnectionPool" do
          text = DockerSdkError.connect_error_text(connect_error(Errno::ECONNREFUSED), "https://127.0.0.1:2376")
          text.must_include("HTTPSConnectionPool(host='127.0.0.1', port=2376)")
          text.must_include("urllib3.connection.HTTPSConnection")
        end
      end

      describe ".transport_error_text without a docker_host" do
        it "uses the unix-socket tuple shape when no docker_host is known" do
          ex = Socket::ConnectError.from_os_error("connect", Errno::ENOENT)
          DockerSdkError.transport_error_text(ex, nil)
            .must_equal("('Connection aborted.', FileNotFoundError(2, 'No such file or directory'))")
        end
      end
    end

    describe "DockerClient docker_host resolution" do
      it "prefers the docker_host param over the task environment overlay and the process env" do
        params = {"docker_host" => "unix:///a.sock", "_environment" => %({"DOCKER_HOST": "unix:///b.sock"})}
        DockerClient.resolved_docker_host(params).must_equal("unix:///a.sock")
      end

      it "falls back to the task environment overlay's DOCKER_HOST (real's env_fallback over the module env)" do
        params = {"_environment" => %({"DOCKER_HOST": "unix:///b.sock"})}
        DockerClient.resolved_docker_host(params).must_equal("unix:///b.sock")
      end

      it "ignores a malformed environment overlay instead of failing" do
        params = {"_environment" => "not json"} of String => String
        DockerClient.env_overlay(params).must_equal({} of String => String)
      end
    end
  end
end
