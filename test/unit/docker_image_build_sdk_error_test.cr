require "../minitest_helper"

# Pins plugins/docker_image_build.cr's "SDK-error" wording path - main()'s
# `except DockerException` wrap ("An unexpected Docker error occurred: {e}").
#
# Source-reading community.docker 5.2.1 (this module is CLI-client only,
# _common_cli.py): no SDK APIError can escape docker_image_build's module
# body - the module builds no Engine API client at all, and since the image
# lookup also runs through the CLI (`docker image ls`, live-verified
# 2026-10-06) even daemon failures surface in the CLI run_command shape
# (see docker_image_build_lookup_test.cr), not in any SDK wording. The ONLY
# DockerException this module raises is _api/auth.py resolve_repository_name's
# InvalidRepository, reached from find_image when its image-lookup chain
# returned NO rows (an existing image short-circuits before it), with two
# messages (live-verified 2026-10-06 against ansible-core 2.19.11 +
# community.docker 5.2.1 driving a real docker CLI 29.8.2 + buildx plugin
# against a podman `system service` socket):
#
#   "An unexpected Docker error occurred: Repository name cannot contain a
#    scheme (http://foo)"                    (name: "http://foo")
#   "Building foo-/bar:latest failed"       (name: "foo-/bar" - the
#    InvalidIndex hyphen check never fires, because split_repo_name maps the
#    slash-less name to the docker.io index; the build itself rejects the
#    tag with the run_command shape - but a registry-qualified name like
#    "registry.example.com-/thing" DOES hit the hyphen check, live-verified
#    the same way)
#
# The registered shape is fail_json(msg=..., exception=...): kwargs lead,
# then failed, msg, changed, exception - no stdout_lines/stderr_lines (the
# controller only derives them from a stdout/stderr, which the wrap has
# none of).
#
# The fake docker CLI below answers both probes (version + the buildx
# gate's info call) and returns NO rows for `image ls`, which is what
# drives find_image into resolve_repository_name. The gate-closed variants
# live in docker_image_build_buildx_test.cr; the lookup-success variants
# live in docker_image_build_lookup_test.cr.
describe "docker_image_build DockerException wrap" do
  # version exits 0 silently, info prints a ClientInfo carrying the buildx
  # plugin, image ls prints nothing (empty lookup), buildx build fails
  # loudly (a build must never run in these tests).
  private def build_dir : String
    dir = PluginSpecHelper.tmp_path("dib-build")
    FileUtils.mkdir_p(dir)
    dir
  end

  private def fake_docker_cli : String
    path = PluginSpecHelper.tmp_path("dib-fake-docker")
    File.write(path, "#!/bin/sh\ncase \" $* \" in\n  *\" info \"*)\n    printf '%s' '{\"ClientInfo\": {\"Plugins\": [{\"Name\": \"buildx\", \"Version\": \"v0.17.0\"}]}}'\n    ;;\n  *\" buildx build \"*)\n    echo 'buildx must not run here' >&2\n    exit 1\n    ;;\nesac\nexit 0\n")
    File.chmod(path, 0o755)
    path
  end

  it "fails a scheme-bearing name with the InvalidRepository wrap message" do
    cli = fake_docker_cli
    result = PluginSpecHelper.run("docker_image_build", {
      "name"       => "http://foo",
      "path"       => build_dir,
      "docker_cli" => cli,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("An unexpected Docker error occurred: Repository name cannot contain a scheme (http://foo)")
  end

  it "fails a hyphen-index name with the InvalidRepository wrap message" do
    cli = fake_docker_cli
    result = PluginSpecHelper.run("docker_image_build", {
      "name"       => "registry.example.com-/thing",
      "path"       => build_dir,
      "docker_cli" => cli,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("An unexpected Docker error occurred: Invalid index name (registry.example.com-). Cannot begin or end with a hyphen.")
  end

  it "does not fire the wrap when the image lookup finds the image" do
    # The raise is gated on the image-lookup chain returning no rows; with
    # a found image real short-circuits resolve_repository_name (and, with
    # rebuild: never, returns before any build). A found image under a
    # scheme-bearing name is unreachable in practice (no daemon accepts
    # such a reference), so the gate is pinned with a valid name.
    cli = PluginSpecHelper.tmp_path("dib-fake-docker")
    File.write(cli, "#!/bin/sh\ncase \" $* \" in\n  *\" info \"*)\n    printf '%s' '{\"ClientInfo\": {\"Plugins\": [{\"Name\": \"buildx\", \"Version\": \"v0.17.0\"}]}}'\n    ;;\n  *\" image ls \"*)\n    printf '%s\\n' '{\"Repository\": \"valid-name\", \"Tag\": \"latest\", \"Digest\": \"sha256:d1\", \"ID\": \"sha256:abc\"}'\n    ;;\n  *\" image inspect \"*)\n    printf '%s' '[{\"Id\": \"sha256:abc\", \"RepoTags\": [\"valid-name:latest\"]}]'\n    ;;\n  *\" buildx build \"*)\n    echo 'buildx must not run here' >&2\n    exit 1\n    ;;\nesac\nexit 0\n")
    File.chmod(cli, 0o755)
    result = PluginSpecHelper.run("docker_image_build", {
      "name"       => "valid-name",
      "path"       => build_dir,
      "docker_cli" => cli,
    })

    result["failed"].as_bool.must_equal(false)
    result["changed"].as_bool.must_equal(false)
    result["msg"]?.must_be_nil
    result["image"]["Id"].as_s.must_equal("sha256:abc")
  end

  it "registers the wrap shape with exception leading and no stdout_lines" do
    cli = fake_docker_cli
    result = PluginSpecHelper.run("docker_image_build", {
      "name"       => "http://foo",
      "path"       => build_dir,
      "docker_cli" => cli,
    })

    result["exception"].as_s.must_equal("(traceback unavailable)")
    result.as_h.keys.must_equal(%w[exception failed msg changed])
    result.as_h.has_key?("stdout_lines").must_equal(false)
    result.as_h.has_key?("stderr_lines").must_equal(false)
  end
end
