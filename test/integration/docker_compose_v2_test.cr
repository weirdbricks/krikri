require "../minitest_helper"
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
  # podman socket) skip the live block instead of failing it. Process.run
  # itself raises when the docker binary doesn't exist at all (bare CI
  # container), so that case also skips.
  io = IO::Memory.new
  begin
    status = Process.run("docker", ["compose", "ls"], output: io, error: io)
  rescue File::NotFoundError
    return false
  end
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
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("one of the following is required")
  end

  it "fails when project_src is not a directory" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/nonexistent/r#{Process.pid}/compose",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("is not a directory")
  end

  it "fails with the real module's missing-compose-file message on an empty project dir" do
    dir = File.tempname("dcv2-empty", ".d")
    Dir.mkdir(dir)
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => dir,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("does not contain compose.yaml, compose.yml, docker-compose.yaml, or docker-compose.yml")
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
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Cannot find Compose file \"missing.yaml\"")
  ensure
    FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
  end

  it "fails when definition: is given without project_name (required_by)" do
    # definition: is a DICT param, so it travels through the config as a
    # stringified JSON object (the engine serializes every task param to
    # a string before the plugin sees it - a raw Hash in "params" is a
    # shape the engine never produces).
    binary = File.join(PluginSpecHelper::PLUGINS_DIR, "docker_compose_v2")
    config = {
      "host"   => {"name" => "localhost", "user" => ENV["USER"]? || "root", "port" => 22},
      "params" => {
        "definition" => %({"services": {"sleeper": {"image": "busybox:latest"}}}),
      },
      "vars" => {} of String => String,
    }
    output = IO::Memory.new
    Process.run(binary, input: IO::Memory.new(config.to_json), output: output, error: Process::Redirect::Inherit)
    result = JSON.parse(output.to_s)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("missing parameter(s) required by 'definition': project_name")
  end

  it "rejects an invalid state choice" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/tmp",
      "state"       => "destroyed",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("value of state must be one of")
  end
end

describe "docker_compose_v2 plugin (live docker)" do
  # Live podman runtime and project names derived from the (shared) suite pid:
  # never run alongside sibling workers (see test/minitest_helper.cr).
  serial!

  it "converges a project and is idempotent on re-run" do
    skip "docker compose CLI not available" unless compose_available?

    dir = File.tempname("dcv2-live", ".d")
    Dir.mkdir(dir)
    File.write(File.join(dir, "compose.yaml"), live_compose_yaml)
    project_name = "krikri-spec-#{Process.pid}"

    first = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => dir,
      "project_name" => project_name,
    })
    falsey?(first["failed"]?.try(&.as_bool)).must_equal(true, first["msg"]?.try(&.raw).to_s)
    first["changed"].as_bool.must_equal(true, "first up should create the container")

    second = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => dir,
      "project_name" => project_name,
    })
    falsey?(second["failed"]?.try(&.as_bool)).must_equal(true, second["msg"]?.try(&.raw).to_s)
    second["changed"].as_bool.must_equal(false, "second up should be a no-op (warm-run idempotency)")

    stopped = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => dir,
      "project_name" => project_name,
      "state"        => "stopped",
    })
    falsey?(stopped["failed"]?.try(&.as_bool)).must_equal(true, stopped["msg"]?.try(&.raw).to_s)
    stopped["changed"].as_bool.must_equal(true, "stopping a running project reports changed")

    stopped_again = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => dir,
      "project_name" => project_name,
      "state"        => "stopped",
    })
    falsey?(stopped_again["failed"]?.try(&.as_bool)).must_equal(true, stopped_again["msg"]?.try(&.raw).to_s)
    stopped_again["changed"].as_bool.must_equal(false, "stopping an already-stopped project is a no-op (real module's _are_containers_stopped gate)")

    down = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"    => dir,
      "project_name"   => project_name,
      "state"          => "absent",
      "remove_volumes" => "true",
    })
    falsey?(down["failed"]?.try(&.as_bool)).must_equal(true, down["msg"]?.try(&.raw).to_s)
  ensure
    if dir && Dir.exists?(dir)
      cleanup_err = IO::Memory.new
      Process.run("docker", ["compose", "-p", "krikri-spec-#{Process.pid}", "down", "--volumes", "--remove-orphans"], error: cleanup_err)
      FileUtils.rm_r(dir)
    end
  end
end

# Registered-result shape parity for docker_compose_v2, live-verified
# key-for-key against real ansible-core 2.19.11 + community.docker 5.2.1:
# a successful run registers changed/actions/stdout/stderr (with an
# empty one dropped)/containers/images - and NO msg at all.
describe "docker_compose_v2 result shape" do
  # Live podman runtime and project names derived from the (shared) suite pid:
  # never run alongside sibling workers (see test/minitest_helper.cr).
  serial!

  it "matches real's up key set and order" do
    skip "docker compose CLI not available" unless compose_available?

    dir = File.tempname("dcv2-shape", ".d")
    Dir.mkdir(dir)
    File.write(File.join(dir, "compose.yaml"), live_compose_yaml)
    project_name = "krikri-kp-dk2-shape-#{Process.pid}"
    begin
      up = PluginSpecHelper.run("docker_compose_v2", {
        "project_src" => dir, "project_name" => project_name,
      })
      falsey?(up["failed"]?.try(&.as_bool)).must_equal(true, up.to_json)
      up.as_h.keys.to_a.must_equal(["changed", "actions", "stderr", "containers", "images", "failed"])
      up["actions"].as_a.all? { |a| a.as_h.keys.to_a == ["what", "id", "status"] }.must_equal(true)
      up["containers"].as_a.all? { |entry| entry.as_h["Names"].as_a.map(&.as_s).size >= 1 }.must_equal(true)
      up["images"].as_a.select { |image| image.as_h.has_key?("ID") }.wont_be_empty

      PluginSpecHelper.run("docker_compose_v2", {
        "project_src" => dir, "project_name" => project_name, "state" => "absent",
      })
    ensure
      Process.run("docker", ["compose", "--project-name", project_name, "-f",
                             File.join(dir, "compose.yaml"), "down", "--volumes", "--remove-orphans"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      FileUtils.rm_rf(dir)
    end
  end

  it "matches real's down key set and order" do
    skip "docker compose CLI not available" unless compose_available?

    dir = File.tempname("dcv2-shape-down", ".d")
    Dir.mkdir(dir)
    File.write(File.join(dir, "compose.yaml"), live_compose_yaml)
    project_name = "krikri-kp-dk2-shape-#{Process.pid}"
    begin
      PluginSpecHelper.run("docker_compose_v2", {
        "project_src" => dir, "project_name" => project_name,
      })
      down = PluginSpecHelper.run("docker_compose_v2", {
        "project_src" => dir, "project_name" => project_name, "state" => "absent",
      })
      falsey?(down["failed"]?.try(&.as_bool)).must_equal(true, down.to_json)
      down.as_h.keys.to_a.must_equal(["changed", "actions", "stderr", "containers", "images", "failed"])
      down["containers"].as_a.must_be_empty
    ensure
      Process.run("docker", ["compose", "--project-name", project_name, "-f",
                             File.join(dir, "compose.yaml"), "down", "--volumes", "--remove-orphans"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      FileUtils.rm_rf(dir)
    end
  end
end
