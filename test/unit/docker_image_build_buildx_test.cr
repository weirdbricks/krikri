require "../minitest_helper"

# Pins plugins/docker_image_build.cr's buildx-plugin gate against real
# community.docker.docker_image_build's ImageBuilder.__init__ (live-verified
# 2026-10-06 against ansible-core 2.19.11 + community.docker 5.2.1 on an
# Ubuntu host with docker.io installed but NO buildx plugin, daemon stubbed):
#
#   {"failed": true,
#    "msg": "Docker CLI /usr/bin/docker does not have the buildx plugin installed",
#    "changed": false,
#    "exception": "(traceback unavailable)"}
#
# real's gate is get_client_plugin_info('buildx') in ImageBuilder.__init__:
# `docker info --format '{{ json . }}'` (call_cli_json, check_rc=True), then
# a scan of ClientInfo.Plugins for Name == 'buildx'. It runs AFTER argument
# validation and the CLI version probe, but BEFORE the path/dockerfile/tag
# checks and BEFORE any Engine-API use - so a missing buildx plugin masks a
# nonexistent path too (both daemon behaviors in the live run: the gate is
# purely CLI-side, the daemon never gets consulted).
#
# The fake docker CLI scripts below stand in for the real CLI the same way
# the version-probe tests do: docker_cli points at a tmp-dir script whose
# argv contains 'version' (probe) or 'info' (buildx gate).
BUILDX_MISSING_MSG_SUFFIX = " does not have the buildx plugin installed"

private def buildx_test_cli(info_stdout : String) : String
  path = PluginSpecHelper.tmp_path("dib-buildx-docker")
  info = info_stdout.gsub("'", "'\\''")
  File.write(path, "#!/bin/sh\ncase \" $* \" in\n  *\" info \"*)\n    printf '%s' '#{info}'\n    ;;\nesac\nexit 0\n")
  File.chmod(path, 0o755)
  path
end

describe "docker_image_build buildx plugin gate" do
  it "fails with real's buildx-missing wording before the path check" do
    cli = buildx_test_cli(%({"ClientInfo": {"Plugins": []}}))

    result = PluginSpecHelper.run("docker_image_build", {
      "name"       => "krikri/thing",
      "path"       => "/tmp/krikri-no-such-build-dir",
      "docker_cli" => cli,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Docker CLI #{cli}#{BUILDX_MISSING_MSG_SUFFIX}")
    result["changed"].as_bool.must_equal(false)
    result["exception"].as_s.must_equal("(traceback unavailable)")
    result.as_h.keys.must_equal(%w[failed msg changed exception])
  end

  it "fails with real's buildx-missing wording when Plugins is absent" do
    cli = buildx_test_cli(%({"ClientInfo": {}}))

    result = PluginSpecHelper.run("docker_image_build", {
      "name"       => "krikri/thing",
      "path"       => "/tmp/krikri-no-such-build-dir",
      "docker_cli" => cli,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Docker CLI #{cli}#{BUILDX_MISSING_MSG_SUFFIX}")
  end

  it "continues past the gate to the path check when buildx is present" do
    cli = buildx_test_cli(%({"ClientInfo": {"Plugins": [{"Name": "buildx", "Version": "v0.17.0"}]}}))

    result = PluginSpecHelper.run("docker_image_build", {
      "name"       => "krikri/thing",
      "path"       => "/tmp/krikri-no-such-build-dir",
      "docker_cli" => cli,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("\"/tmp/krikri-no-such-build-dir\" is not an existing directory")
  end

  it "fails in the run_command shape when the info call exits non-zero" do
    # version passes, info fails - pins the gate's own non-zero arm (not
    # the version probe's).
    cli = PluginSpecHelper.tmp_path("dib-buildx-docker")
    File.write(cli, "#!/bin/sh\ncase \" $* \" in\n  *\" version \"*) exit 0 ;;\n  *\" info \"*) echo 'info blew up' >&2 ; exit 1 ;;\nesac\nexit 0\n")
    File.chmod(cli, 0o755)

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "krikri/thing",
      "path"        => "/tmp/krikri-no-such-build-dir",
      "docker_cli"  => cli,
      "docker_host" => "unix:///tmp/krikri-no-such-buildx-sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("info blew up")
    result["cmd"].as_s.must_equal("#{cli} --host unix:///tmp/krikri-no-such-buildx-sock info --format '{{ json . }}'")
    result["rc"].as_i.must_equal(1)
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.must_equal("info blew up\n")
    result.as_h.keys.must_equal(%w[cmd rc stdout stderr failed msg stdout_lines stderr_lines changed exception])
  end

  it "fails in the call_cli_json shape when the info output is not JSON" do
    cli = buildx_test_cli("not json")

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "krikri/thing",
      "path"        => "/tmp/krikri-no-such-build-dir",
      "docker_cli"  => cli,
      "docker_host" => "unix:///tmp/krikri-no-such-buildx-sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Error while parsing JSON output of #{cli} --host unix:///tmp/krikri-no-such-buildx-sock info --format '{{ json . }}': ")
    result["msg"].as_s.must_include("\nJSON output: not json\n\nError output:\n")
    result["cmd"].as_s.must_equal("#{cli} --host unix:///tmp/krikri-no-such-buildx-sock info --format '{{ json . }}'")
  end

  it "fails with the podman-suspicion wording when ClientInfo is absent" do
    cli = buildx_test_cli(%({"ServerInfo": {}}))

    result = PluginSpecHelper.run("docker_image_build", {
      "name"       => "krikri/thing",
      "path"       => "/tmp/krikri-no-such-build-dir",
      "docker_cli" => cli,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Cannot determine Docker client information. Are you maybe using podman instead of docker?")
  end
end
