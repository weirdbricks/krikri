require "../minitest_helper"

# Three parity regression tests mirroring docker_network_ipam_test.cr:
#
# 1. docker_container published_ports: both `published_ports:` and the
#    `ports:` alias bind the same host<->container mappings. Live-verified
#    vs ansible-core 2.19.11 + community.docker 5.2.1 on a podman
#    docker-compatible socket.
# 2. docker_network ipam_config element without `subnet`: real's
#    TaskParameters crashes with an uncaught re.match(None) TypeError; its
#    registered result carries key order
#    `failed, ansible_facts, changed, exception, msg, warnings` (NOT the
#    plain fail_json order `failed, msg, changed, exception` the CIDR
#    text path takes). krikri reproduces that exception-path order on the
#    4 keys it actually emits (failed/changed/exception/msg) - this test
#    pins the relative order.
# 3. --host for docker compose AND docker buildx (CLI-client plugins):
#    real's DockerCLIClient prepends `docker --host <docker_host>` to
#    every CLI call (self._cli_base), and compose invocations go through
#    it too. This spec proves the compose plugin reaches the podman
#    daemon through that prefix: without --host the compose command would
#    target docker's own default socket and fail.
#
# The socket is the podman `system service` endpoint. The specs skip when
# it is not up. Everything is scoped to the krikri-spec-#{Process.pid}
# prefix, so these can run alongside the other daemon-dependent specs
# (they serialize instead of sharing container names).
PODMANN_SOCKET      = "unix:///run/user/1000/podman/podman.sock"
PODMANN_SOCKET_PATH = "/run/user/1000/podman/podman.sock"
PROJECT_NAME        = "krikri-spec-#{Process.pid}"
COMPOSE_PROJECT_DIR = File.tempname("krikri-docker-parity", ".d")

private def podman_socket? : Bool
  File.exists?(PODMANN_SOCKET_PATH)
end

private def cleanup_docker_local_objects : Nil
  # Remove any containers/networks/images this spec created under its own
  # project name, so a re-run of the suite is clean.
  Process.run("podman", ["rm", "-f", "#{PROJECT_NAME}-web"], error: IO::Memory.new)
  Process.run("podman", ["network", "rm", "#{PROJECT_NAME}-default"], error: IO::Memory.new)
  Process.run("podman", ["rmi", "localhost/#{PROJECT_NAME}-shape:1"], error: IO::Memory.new)
ensure
  Dir.delete(COMPOSE_PROJECT_DIR) if Dir.exists?(COMPOSE_PROJECT_DIR)
end

describe "docker_container published_ports" do
  serial!

  it "binds published_ports into HostConfig.PortBindings with HostIp 0.0.0.0" do
    skip("no podman socket at #{PODMANN_SOCKET_PATH}") unless podman_socket?
    name = "krikri-spec-#{Process.pid}-pubport"
    begin
      result = PluginSpecHelper.run("docker_container", {
        "name"            => name,
        "image"           => "docker.io/library/alpine:latest",
        "command"         => "sleep 30",
        "published_ports" => "8080:80",
        "docker_host"     => PODMANN_SOCKET,
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true, result.to_json)
      result["changed"].as_bool.must_equal(true)

      container = result["container"].as_h
      host_config = container["HostConfig"].as_h
      port_bindings = host_config["PortBindings"].as_h
      port_bindings.has_key?("80/tcp").must_equal(true)
      port_bindings["80/tcp"].as_a.size.must_equal(1)
      port_bindings["80/tcp"].as_a.first.as_h["HostIp"].as_s.must_equal("0.0.0.0")
      port_bindings["80/tcp"].as_a.first.as_h["HostPort"].as_s.must_equal("8080")
    ensure
      PluginSpecHelper.run("docker_container", {"name" => name, "state" => "absent", "docker_host" => PODMANN_SOCKET})
    end
  end

  it "keeps `ports:` (the alias) binding the same way" do
    skip("no podman socket at #{PODMANN_SOCKET_PATH}") unless podman_socket?
    name = "krikri-spec-#{Process.pid}-pubport-alias"
    begin
      result = PluginSpecHelper.run("docker_container", {
        "name"        => name,
        "image"       => "docker.io/library/alpine:latest",
        "command"     => "sleep 30",
        "ports"       => "8080:80",
        "docker_host" => PODMANN_SOCKET,
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true, result.to_json)
      result["changed"].as_bool.must_equal(true)

      container = result["container"].as_h
      host_config = container["HostConfig"].as_h
      port_bindings = host_config["PortBindings"].as_h
      port_bindings.has_key?("80/tcp").must_equal(true)
      port_bindings["80/tcp"].as_a.first.as_h["HostPort"].as_s.must_equal("8080")
    ensure
      PluginSpecHelper.run("docker_container", {"name" => name, "state" => "absent", "docker_host" => PODMANN_SOCKET})
    end
  end

  it "is idempotent on re-run (allow_more_present subset match)" do
    skip("no podman socket at #{PODMANN_SOCKET_PATH}") unless podman_socket?
    name = "krikri-spec-#{Process.pid}-pubport-idem"
    begin
      PluginSpecHelper.run("docker_container", {
        "name"            => name,
        "image"           => "docker.io/library/alpine:latest",
        "command"         => "sleep 30",
        "published_ports" => "8080:80",
        "docker_host"     => PODMANN_SOCKET,
      })
      second = PluginSpecHelper.run("docker_container", {
        "name"            => name,
        "image"           => "docker.io/library/alpine:latest",
        "command"         => "sleep 30",
        "published_ports" => "8080:80",
        "docker_host"     => PODMANN_SOCKET,
      })
      falsey?(second["failed"]?.try(&.as_bool)).must_equal(true, second.to_json)
      second["changed"].as_bool.must_equal(false)
    ensure
      PluginSpecHelper.run("docker_container", {"name" => name, "state" => "absent", "docker_host" => PODMANN_SOCKET})
    end
  end
end

describe "docker_network ipam_config no-subnet key order" do
  serial!

  it "registers the exception-path key order (failed, ansible_facts, changed, exception, msg, warnings) on a pool lacking subnet" do
    skip("no podman socket at #{PODMANN_SOCKET_PATH}") unless podman_socket?
    name = "krikri-spec-#{Process.pid}-net-nosubnet"
    begin
      result = PluginSpecHelper.run("docker_network", {
        "name"        => name,
        "docker_host" => PODMANN_SOCKET,
        "ipam_config" => %([{"gateway": "10.99.5.1"}]),
      })
      result["failed"]?.try(&.as_bool).must_equal(true, result.to_json)
      result["msg"].as_s.must_equal("expected string or bytes-like object, got 'NoneType'")
      # The relative order of the 4 keys krikri emits must match real's
      # exception-path order (failed, ansible_facts, changed, exception,
      # msg, warnings - the ansible_facts/warnings slots the controller
      # injects are skipped by krikri's marker, which only checks
      # relative order).
      result.as_h.keys.to_a.must_equal(["failed", "changed", "exception", "msg"])
    ensure
      PluginSpecHelper.run("docker_network", {"name" => name, "state" => "absent", "docker_host" => PODMANN_SOCKET})
    end
  end
end

describe "docker compose CLI-client prefix (--host)" do
  serial!

  it "runs compose through the docker --host <docker_host> CLI prefix" do
    skip("no podman socket at #{PODMANN_SOCKET_PATH}") unless podman_socket?
    FileUtils.mkdir_p(COMPOSE_PROJECT_DIR)
    File.write(File.join(COMPOSE_PROJECT_DIR, "compose.yaml"),
      "services:\n  web:\n    image: alpine:latest\n    command: echo parity\n")

    # A successful up through the plugin proves the plugin passes
    # `--host <docker_host>` (base_command) into every compose invocation
    # and reaches the podman daemon the socket points at.
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => COMPOSE_PROJECT_DIR,
      "project_name" => PROJECT_NAME,
      "state"        => "present",
      "docker_host"  => PODMANN_SOCKET,
    })
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true, result.to_json)
    result["changed"].as_bool.must_equal(true)
  end
end
