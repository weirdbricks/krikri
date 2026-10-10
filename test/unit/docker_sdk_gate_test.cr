require "../minitest_helper"
require "file_utils"

# The import gate real's five SDK-based docker modules run at client
# construction (docker_client.cr's sdk_import_gate, raised through
# DockerClient.build). community.docker 5.2.1's docker_container/
# docker_image/docker_network/docker_network_info/docker_login import the
# collection's VENDORED SDK (module_utils/_common_api + _api/) and never
# import the external `docker` package - live-probed with the pinned pair
# (ansible-core 2.19.11 + 5.2.1): a python3-docker-less interpreter runs
# docker_network fine. Their client init's gate is the vendored SDK's own
# _api/api/client.py fail_on_missing_imports: `requests` must import,
# else missing_required_lib("requests") wording (traceback in the [ERROR]
# block only). _common.py's external-SDK gate (docker>=5.0.0 wording +
# MIN_DOCKER_VERSION) belongs to the docker_swarm*/docker_node*/
# docker_config/docker_secret family, and there is no version branch on
# the vendored path.
#
# The branches are forced deterministically through a PATH shim: the shim
# wins the gate's INTERPRETER_FALLBACK discovery and answers the probe
# (`import requests`) with whatever the spec needs.
require "../../src/krikri/base_plugin"
require "../../src/krikri/plugin_helpers/docker_client"

GATE_SHIM_PY = "/opt/krikri-gate-shim/bin/python3.13"

private def with_gate_shim(requests_behavior : String, &) : Nil
  dir = PluginSpecHelper.tmp_path("docker-sdk-gate-shim")
  FileUtils.rm_rf(dir)
  FileUtils.mkdir_p(dir)
  interpreter = File.join(dir, Krikri::INTERPRETER_FALLBACK.first)
  File.write(interpreter, <<-SHIM)
    #!/bin/sh
    case "$*" in
      *"print(sys.executable)"*) echo "#{GATE_SHIM_PY}" ;;
      *"import requests"*)
        #{requests_behavior}
        exit $? ;;
      *) exit 0 ;;
    esac
    SHIM
  File.chmod(interpreter, 0o755)

  original_path = ENV["PATH"]?
  ENV["PATH"] = "#{dir}:#{original_path}"
  begin
    yield
  ensure
    ENV["PATH"] = original_path if original_path
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end
end

describe "docker sdk import gate" do
  serial!

  it "fails with the exact missing-lib wording when requests cannot import" do
    Krikri::PluginHelpers::DockerClient.reset_sdk_import_gate
    with_gate_shim(%(echo "ModuleNotFoundError: No module named 'requests'" >&2; exit 1)) do
      expected = "Failed to import the required Python library (requests) " \
                 "on #{System.hostname}'s Python #{GATE_SHIM_PY}. " \
                 "Please read the module documentation and install it in the appropriate location. " \
                 "If the required library is installed, but Ansible is using the wrong Python interpreter, " \
                 "please consult the documentation on ansible_python_interpreter"
      error = assert_raises(Krikri::SdkImportGateError) do
        Krikri::PluginHelpers::DockerClient.sdk_import_gate
      end
      error.message.must_equal(expected)
      error.detail.must_equal("#{expected}: No module named 'requests'")
    end
  end

  it "passes on a python3-docker-less interpreter - the vendored SDK needs only requests" do
    # The shim fails `import docker` (a python3-docker-less host) but
    # imports requests cleanly - exactly the round 5410000 host shape,
    # where real 5.2.1's in-scope modules SUCCEED (the external-SDK gate
    # the round witnessed belongs to the out-of-scope docker_swarm
    # family). The gate must stay silent here.
    docker_fails = "case \"$*\" in *\"import docker\"*) " \
                   "echo \"ModuleNotFoundError: No module named 'docker'\" >&2; exit 1 ;; " \
                   "*) exit 0 ;; esac"
    Krikri::PluginHelpers::DockerClient.reset_sdk_import_gate
    with_gate_shim(docker_fails) do
      Krikri::PluginHelpers::DockerClient.sdk_import_gate
    end
  end

  it "passes when requests imports under the host's own interpreter (skipped without requests)" do
    probe = Process.run("python3", {"-c", "import requests"}, error: Process::Redirect::Close)
    skip "requests not importable under this host's python3 (the shim specs cover the failure branch)" unless probe.success?

    Krikri::PluginHelpers::DockerClient.reset_sdk_import_gate
    Krikri::PluginHelpers::DockerClient.sdk_import_gate
  end
end
