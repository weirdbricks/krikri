require "../minitest_helper"
require "file_utils"

# Registered-result shape parity for community.docker.docker_image_build,
# live-verified key-for-key against ansible-core 2.19.11 +
# community.docker 5.2.1 driving a REAL BuildKit builder.
#
# The module shells out to `docker buildx build` (it is CLI-only - it
# probes `docker info`'s ClientInfo.Plugins for buildx and fails without
# it), so unlike the Docker-API shape specs (docker_result_shape_test.cr)
# this needs a BuildKit-capable docker CLI, not just a socket. On the dev
# box that is: a static docker CLI + buildx plugin under
# /tmp/km-docker-build/bin with DOCKER_CONFIG=/tmp/km-docker-build/
# docker-config, a buildkitd (started under rootlesskit) reachable as a
# buildx `remote` driver at tcp://127.0.0.1:1234, and the module's
# daemon-facing CLI probes talking to a rootless podman `system service`
# socket. `{{ r | to_json }}` dumps from a ansible-playbook run of
# the same shapes pinned the order (see the per-spec comments); the
# specs skip when that stack is not up.
#
# Everything here stays under the km-docker-build- prefix (the
# localhost/km-docker-build-shape image is this file's own, built with
# podman and removed again) and the specs talk to the same
# builder/daemon, so they serialize on the shared state mutex.
BUILD_SHAPE_SOCKET        = "unix:///tmp/km-docker-build/podman.sock"
BUILD_SHAPE_SOCKET_PATH   = "/tmp/km-docker-build/podman.sock"
BUILD_SHAPE_DOCKER_CONFIG = "/tmp/km-docker-build/docker-config"

# `skip` is the spec DSL's own method, so it can only be called from
# inside an `it` block - each spec guards itself.
private def build_shape_buildkit? : Bool
  return false unless File.exists?(BUILD_SHAPE_SOCKET_PATH)
  io = IO::Memory.new
  begin
    status = Process.run("docker", ["buildx", "du"], output: io, error: io,
      env: {"DOCKER_CONFIG" => BUILD_SHAPE_DOCKER_CONFIG})
  rescue File::NotFoundError
    return false
  end
  status.success? && !io.to_s.includes?("Cannot connect")
end

private def build_shape_env : Hash(String, String)
  {"DOCKER_CONFIG" => BUILD_SHAPE_DOCKER_CONFIG,
   "PATH"          => "/tmp/km-docker-build/bin:#{ENV["PATH"]}"}
end

private def build_shape_params(name : String, ctx : String, extra : Hash(String, String) = {} of String => String) : Hash(String, String)
  {
    "name"        => name,
    "tag"         => "1",
    "path"        => ctx,
    "docker_host" => BUILD_SHAPE_SOCKET,
  }.merge(extra)
end

# A tiny FROM-scratch build context under this spec's private scratch
# space; the build needs no network (no FROM image to pull).
private def write_build_context(dir : String, dockerfile : String) : Nil
  FileUtils.rm_rf(dir)
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "Dockerfile"), dockerfile)
  File.write(File.join(dir, "hello.txt"), "hello\n")
end

# Pods the daemon's store with the tiny localhost/km-docker-build-shape:1
# image via podman itself (no registry), so the rebuild: never
# already-present path can be exercised - a remote-driver build's default
# output stays in the builder's cache and never reaches the store.
private def build_shape_seed_image : Nil
  ctx = PluginSpecHelper.tmp_path("docker-image-build-shape-seed")
  FileUtils.rm_rf(ctx)
  Dir.mkdir_p(ctx)
  File.write(File.join(ctx, "Dockerfile"), "FROM scratch\nLABEL km=docker-build-shape\n")
  Process.run("podman", ["build", "-t", "localhost/km-docker-build-shape:1", "-f",
                         File.join(ctx, "Dockerfile"), ctx], output: Process::Redirect::Close)
end

private def build_shape_unseed_image : Nil
  Process.run("podman", ["rmi", "localhost/km-docker-build-shape:1"],
    output: Process::Redirect::Close, error: Process::Redirect::Close)
end

describe "docker_image_build result shape" do
  serial!

  it "matches Ansible's successful-build key set and order" do
    skip("no BuildKit-capable docker CLI at #{BUILD_SHAPE_SOCKET_PATH}") unless build_shape_buildkit?
    ctx = PluginSpecHelper.tmp_path("docker-image-build-shape-ctx")
    write_build_context(ctx, "FROM scratch\nLABEL km=docker-build-shape\nCOPY hello.txt /hello.txt\n")
    result = PluginSpecHelper.run("docker_image_build",
      build_shape_params("km-docker-build-shape-build", ctx), env: build_shape_env)
    # real: {"changed": true, "actions": [], "image": {}, "stdout": "",
    #        "stderr": <buildx progress>, "command": ["buildx", "build",
    #        "--progress", "plain", "--tag", "...:1", "--", <path>],
    #        "stdout_lines": [], "stderr_lines": [...], "failed": false}
    # (`image` is {} unless the build result landed in the daemon's
    # store - a remote-driver build's default output does not.)
    result.as_h.keys.to_a.must_equal([
      "changed", "actions", "image", "stdout", "stderr", "command",
      "stdout_lines", "stderr_lines", "failed",
    ])
    result["changed"].as_bool.must_equal(true)
    result["actions"].as_a.must_be_empty
    result["stdout"].as_s.must_equal("")
    result["stdout_lines"].as_a.must_be_empty
    result["command"].as_a.map(&.as_s).must_equal([
      "buildx", "build", "--progress", "plain", "--tag",
      "km-docker-build-shape-build:1", "--", ctx,
    ])
    result["stderr"].as_s.wont_be_empty
    result["stderr_lines"].as_a.wont_be_empty
    result["failed"].as_bool.must_equal(false)
    result.as_h.has_key?("msg").must_equal(false)
  end

  it "matches Ansible's check-mode key set and order" do
    skip("no BuildKit-capable docker CLI at #{BUILD_SHAPE_SOCKET_PATH}") unless build_shape_buildkit?
    ctx = PluginSpecHelper.tmp_path("docker-image-build-shape-ctx")
    write_build_context(ctx, "FROM scratch\nLABEL km=docker-build-shape\nCOPY hello.txt /hello.txt\n")
    params = build_shape_params("km-docker-build-shape-check", ctx).to_h
      .transform_values { |v| JSON::Any.new(v) }
      .merge({"_ansible_check_mode" => JSON::Any.new(true)})
    result = PluginSpecHelper.run_raw("docker_image_build", params, env: build_shape_env)
    # real check_mode on an absent image:
    # {"changed": true, "actions": [], "image": {}, "failed": false}
    result.as_h.keys.to_a.must_equal(["changed", "actions", "image", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["actions"].as_a.must_be_empty
    result["image"].as_h.must_be_empty
    result["failed"].as_bool.must_equal(false)
    result.as_h.has_key?("msg").must_equal(false)
  end

  it "matches Ansible's already-present key set and order" do
    skip("no BuildKit-capable docker CLI at #{BUILD_SHAPE_SOCKET_PATH}") unless build_shape_buildkit?
    ctx = PluginSpecHelper.tmp_path("docker-image-build-shape-ctx")
    write_build_context(ctx, "FROM scratch\nLABEL km=docker-build-shape\nCOPY hello.txt /hello.txt\n")
    build_shape_seed_image
    result = PluginSpecHelper.run("docker_image_build",
      build_shape_params("localhost/km-docker-build-shape", ctx), env: build_shape_env)
    # real: {"changed": false, "actions": [], "image": {<inspect>},
    #        "failed": false} - the daemon's own inspect dict, verbatim
    result.as_h.keys.to_a.must_equal(["changed", "actions", "image", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["actions"].as_a.must_be_empty
    result["image"]["Id"].as_s.starts_with?("sha256:").must_equal(true)
    result["image"]["RepoTags"].as_a.map(&.as_s).must_equal(["localhost/km-docker-build-shape:1"])
    result["failed"].as_bool.must_equal(false)
    result.as_h.has_key?("msg").must_equal(false)
  ensure
    build_shape_unseed_image
  end

  it "matches Ansible's failed-build key set and order" do
    skip("no BuildKit-capable docker CLI at #{BUILD_SHAPE_SOCKET_PATH}") unless build_shape_buildkit?
    ctx = PluginSpecHelper.tmp_path("docker-image-build-shape-ctx")
    write_build_context(ctx, "THIS IS NOT A VALID DOCKERFILE\n")
    result = PluginSpecHelper.run("docker_image_build",
      build_shape_params("km-docker-build-shape-fail", ctx), env: build_shape_env)
    # real: {"stdout": "", "stderr": <buildx error>, "command": [...],
    #        "failed": true, "msg": "Building ... failed",
    #        "stdout_lines": [], "stderr_lines": [...], "changed": false,
    #        "exception": "(traceback unavailable)"}
    result.as_h.keys.to_a.must_equal([
      "stdout", "stderr", "command", "failed", "msg",
      "stdout_lines", "stderr_lines", "changed", "exception",
    ])
    result["stdout"].as_s.must_equal("")
    result["command"].as_a.map(&.as_s).must_equal([
      "buildx", "build", "--progress", "plain", "--tag",
      "km-docker-build-shape-fail:1", "--", ctx,
    ])
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Building km-docker-build-shape-fail:1 failed")
    result["stderr"].as_s.must_include("unknown instruction: THIS")
    result["stdout_lines"].as_a.must_be_empty
    result["changed"].as_bool.must_equal(false)
    result["exception"].as_s.must_equal("(traceback unavailable)")
  end
end
