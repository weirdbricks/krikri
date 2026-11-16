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
        # from_os_error's static return type is Socket::Error, but every
        # instance it builds is a ConnectError (the runtime class the
        # plugins' rescue clauses see).
        def connect_error(errno : Errno) : Socket::ConnectError
          Socket::ConnectError.from_os_error("connect", errno).as(Socket::ConnectError)
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

        it "probes through Crystal's non-blocking EINPROGRESS to real's completion errno (live connect to a closed port)" do
          # Crystal's own TCPSocket/HTTP::Client connect raises on the
          # immediate EINPROGRESS return without reading SO_ERROR, so the
          # exception real-world code catches carries EINPROGRESS, not the
          # ECONNREFUSED real's blocking connect sees. The rendering must
          # recover the completion verdict (probed live: instant refusal).
          text = DockerSdkError.connect_error_text(connect_error(Errno::EINPROGRESS), "tcp://127.0.0.1:1")
          text.must_equal("Error connecting: Error while fetching server API version: " \
                          "HTTPConnectionPool(host='127.0.0.1', port=1): Max retries exceeded with url: /version " \
                          "(Caused by NewConnectionError('<urllib3.connection.HTTPConnection object at #{text[/object at (0x[0-9a-f]+)>/, 1]}>: " \
                          "Failed to establish a new connection: [Errno 111] Connection refused'))")
        end

        it "keeps the caught errno when the probe cannot reach a verdict (no host context)" do
          # A synthetic EINPROGRESS with no TCP docker_host falls to the
          # unix branch; with a host the probe needs a resolvable endpoint.
          # Here: tcp host whose DNS cannot resolve keeps the caught errno.
          text = DockerSdkError.connect_error_text(connect_error(Errno::EINPROGRESS), "tcp://krikri-no-such-host.invalid:2375")
          text.must_include("Failed to establish a new connection: [Errno 115] Operation now in progress")
        end

        it "words an https daemon HTTPSConnectionPool" do
          text = DockerSdkError.connect_error_text(connect_error(Errno::ECONNREFUSED), "https://127.0.0.1:2376")
          text.must_include("HTTPSConnectionPool(host='127.0.0.1', port=2376)")
          text.must_include("urllib3.connection.HTTPSConnection")
        end

        it "renders an unresolvable TCP host in urllib3's NameResolutionError shape (pointer aside)" do
          # A parseable TCP hostname fails at name resolution, which
          # urllib3 reports as NameResolutionError rather than a
          # NewConnectionError. The live lookup supplies the getaddrinfo
          # code the message quotes.
          ex = begin
            Socket::Addrinfo.resolve("krikri-no-such-host.invalid", 2376, type: Socket::Type::STREAM)
            raise "unreachable: the .invalid TLD must not resolve"
          rescue error : Socket::Addrinfo::Error
            error
          end
          text = DockerSdkError.connect_error_text(ex, "tcp://kxqsrj:2376")
          text.must_equal("Error connecting: Error while fetching server API version: " \
                          "HTTPConnectionPool(host='kxqsrj', port=2376): Max retries exceeded with url: /version " \
                          "(Caused by NameResolutionError(\"<urllib3.connection.HTTPConnection object at #{text[/object at (0x[0-9a-f]+)>/, 1]}>: " \
                          "Failed to resolve 'kxqsrj' ([Errno -2] Name or service not known)\"))")
        end

        it "uses the TLS pool for a TLS TCP host" do
          text = DockerSdkError.connect_error_text(connect_error(Errno::ECONNREFUSED), "tcp://127.0.0.1:2375", true)
          text.must_include("HTTPSConnectionPool(host='127.0.0.1', port=2375)")
        end
      end

      describe ".transport_error_text without a docker_host" do
        it "uses the unix-socket tuple shape when no docker_host is known" do
          ex = Socket::ConnectError.from_os_error("connect", Errno::ENOENT).as(Socket::ConnectError)
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

    # The SDK's parse_host() runs inside Client.__init__ (before any
    # request), and real reports its DockerException as
    # "Error connecting: <text>" - byte-verified against docker-py 7.x,
    # the SDK the reference environments' community.docker drives.
    describe "DockerClient.parse_host" do
      it "rejects a scheme-less host with no port (docker-py 7.x no longer defaults one)" do
        assert_raises_message(DockerClient::InvalidDockerHostError,
          "Invalid bind address format: port is required: spcyng") do
          DockerClient.parse_host("spcyng")
        end
      end

      it "reads a scheme-less value as a TCP endpoint, port included" do
        parsed = DockerClient.parse_host("127.0.0.1:2375")
        parsed.tcp?.must_equal(true)
        parsed.host.must_equal("127.0.0.1")
        parsed.port.must_equal(2375)
      end

      it "rejects a scheme the SDK does not know" do
        assert_raises_message(DockerClient::InvalidDockerHostError,
          "Invalid bind address protocol: localhost:2375") do
          DockerClient.parse_host("localhost:2375")
        end
      end

      it "rejects a bare socket path (no unix:// scheme)" do
        assert_raises_message(DockerClient::InvalidDockerHostError,
          "Invalid bind address format: /var/run/docker.sock") do
          DockerClient.parse_host("/var/run/docker.sock")
        end
      end

      it "keeps unix:// paths as socket paths" do
        parsed = DockerClient.parse_host("unix:///tmp/krikri-no-such-sock")
        parsed.tcp?.must_equal(false)
        parsed.socket_path.must_equal("/tmp/krikri-no-such-sock")
      end

      it "treats an empty value and unix:// as the SDK's default socket" do
        DockerClient.parse_host(nil).socket_path.must_be_nil
        DockerClient.parse_host("").socket_path.must_be_nil
        DockerClient.parse_host("unix://").socket_path.must_be_nil
      end

      it "requires a port for tcp:// too, and defaults ssh:// to 22" do
        assert_raises_message(DockerClient::InvalidDockerHostError,
          "Invalid bind address format: port is required: tcp://h") do
          DockerClient.parse_host("tcp://h")
        end
        DockerClient.parse_host("ssh://u@h").port.must_equal(22)
      end
    end
  end
end
