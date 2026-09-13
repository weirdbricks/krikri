require "../spec_helper"
require "file_utils"

# community.docker.docker_compose_v2 - previously an unimplemented
# collection module (rc=4 "unavailable modules" where real ansible ran
# it; mrlesmithjr.blocky is the corpus role). These specs exercise the
# plugin binary directly through the same stdin-JSON entrypoint
# PluginManager uses.
#
# The validation specs need no docker daemon; the live up/stopped/absent
# specs need a working `docker compose` v2 CLI and skip otherwise (the
# same convention as the other daemon-dependent plugins).
private def compose_available? : Bool
  # `docker compose version` alone doesn't touch the daemon - probe with
  # a command that does, so environments whose compose provider can't
  # reach the daemon (e.g. the docker-compose shim over an unreachable
  # podman socket) skip the live block instead of failing it.
  io = IO::Memory.new
  status = Process.run("docker", ["compose", "ls"], output: io, error: io)
  status.success? && !io.to_s.includes?("Cannot connect to the Docker daemon")
end

# A minimal always-running service: busybox sleep. The project needs
# nothing else - no ports, no volumes, no build.
private def live_compose_yaml : String
  <<-'YAML'
    services:
      sleeper:
        image: busybox:latest
        command: sleep 300
  YAML
end

describe "docker_compose_v2 plugin" do
  it "fails when neither project_src nor definition is given" do
    result = PluginSpecHelper.run("docker_compose_v2", {} of String => String)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("one of the following is required")
  end

  it "fails when project_src is not a directory" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/nonexistent/r#{Process.pid}/compose",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("is not a directory")
  end

  it "fails with the real module's missing-compose-file message on an empty project dir" do
    dir = File.tempname("dcv2-empty", ".d")
    Dir.mkdir(dir)
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => dir,
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("does not contain compose.yaml, compose.yml, docker-compose.yaml, or docker-compose.yml")
  ensure
    Dir.delete(dir) if dir && Dir.exists?(dir)
  end

  it "fails when an explicit files: entry does not exist relative to project_src" do
    dir = File.tempname("dcv2-files", ".d")
    Dir.mkdir(dir)
    File.write(File.join(dir, "compose.yaml"), "services: {}\n")
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => dir,
      "files"       => "missing.yaml",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Cannot find Compose file \"missing.yaml\"")
  ensure
    FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
  end

  it "fails when definition: is given without project_name (required_by)" do
    # definition: is a DICT param, so it travels through the config as a
    # JSON object (only the raw config carries the shape - the flattened
    # @params view stringifies it). Run the binary directly with that shape.
    binary = File.join(PluginSpecHelper::PLUGINS_DIR, "docker_compose_v2")
    config = {
      "host"   => {"name" => "localhost", "user" => ENV["USER"]? || "root", "port" => 22},
      "params" => {
        "definition" => {"services" => {"sleeper" => {"image" => "busybox:latest"}}},
      },
      "vars" => {} of String => String,
    }
    output = IO::Memory.new
    Process.run(binary, input: IO::Memory.new(config.to_json), output: output, error: Process::Redirect::Inherit)
    result = JSON.parse(output.to_s)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("project_name is required when definition is used")
  end

  it "rejects an invalid state choice" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/tmp",
      "state"       => "destroyed",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of state must be one of")
  end
end

describe "docker_compose_v2 plugin (live docker)" do
  it "converges a project and is idempotent on re-run" do
    pending! "docker compose CLI not available" unless compose_available?

    dir = File.tempname("dcv2-live", ".d")
    Dir.mkdir(dir)
    File.write(File.join(dir, "compose.yaml"), live_compose_yaml)
    project_name = "krikri-spec-#{Process.pid}"

    first = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => dir,
      "project_name" => project_name,
    })
    first["failed"]?.try(&.as_bool).should be_falsey, first["msg"].as_s
    first["changed"].as_bool.should be_true, "first up should create the container"

    second = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => dir,
      "project_name" => project_name,
    })
    second["failed"]?.try(&.as_bool).should be_falsey, second["msg"].as_s
    second["changed"].as_bool.should be_false, "second up should be a no-op (warm-run idempotency)"

    stopped = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => dir,
      "project_name" => project_name,
      "state"        => "stopped",
    })
    stopped["failed"]?.try(&.as_bool).should be_falsey, stopped["msg"].as_s
    stopped["changed"].as_bool.should be_true, "stopping a running project reports changed"

    stopped_again = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => dir,
      "project_name" => project_name,
      "state"        => "stopped",
    })
    stopped_again["failed"]?.try(&.as_bool).should be_falsey, stopped_again["msg"].as_s
    stopped_again["changed"].as_bool.should be_false, "stopping an already-stopped project is a no-op (real module's _are_containers_stopped gate)"

    down = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"    => dir,
      "project_name"   => project_name,
      "state"          => "absent",
      "remove_volumes" => "true",
    })
    down["failed"]?.try(&.as_bool).should be_falsey, down["msg"].as_s
  ensure
    if dir && Dir.exists?(dir)
      cleanup_err = IO::Memory.new
      Process.run("docker", ["compose", "-p", "krikri-spec-#{Process.pid}", "down", "--volumes", "--remove-orphans"], error: cleanup_err)
      FileUtils.rm_r(dir)
    end
  end
end
