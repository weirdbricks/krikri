require "../minitest_helper"
require "../../src/krikri/base_plugin"
require "../../src/krikri/plugin_helpers/docker_client"

# The vendored Docker SDK (community.docker 5.2.1's _api/api/client.py)
# parses an explicitly pinned api_version at client construction: an
# unparseable value raises StrictVersion's "invalid version number",
# which AnsibleDockerClientBase wraps in "Error connecting: ", and a
# parseable one below the SDK's own minimum (or the module's 1.25
# default) fails too. the krikri-docker client calls every endpoint
# unversioned (see docker_client.cr's class comment), so without
# mirroring the parse a playbook carrying a bogus api_version succeeded
# here where real fails the task (kpg round 000027, issue #1340).
#
# Live-verified against ansible-core 2.19.11 + community.docker 5.2.1 for
# the unparseable case: real fails with
# "Error connecting: invalid version number 'atoobk'" before any daemon
# I/O, so no daemon is needed to exercise any of this.
private def docker_gate_ready? : Bool
  Krikri::PluginHelpers::DockerClient.reset_sdk_import_gate
  python = Krikri.discovered_target_python
  return false unless python

  Process.run(python, {"-c", "import requests"}, error: Process::Redirect::Close).success?
rescue
  false
end

describe "docker api_version client validation" do
  serial!

  it "fails an unparseable api_version like the SDK's StrictVersion parse" do
    skip "requests not importable under this host's python3 (the plugin spec covers it end to end)" unless docker_gate_ready?

    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build({"api_version" => "atoobk"})
    end
    error.message.must_equal("Error connecting: invalid version number 'atoobk'")
  end

  it "parses the api_version before an unusable docker_host decides anything" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    # Real (community.docker 4.7.0/5.2.1, both driving the collection's
    # own _api client) accepts a portless docker_host - "tkvwva" becomes
    # http://tkvwva:2376 - so the pinned api_version's parse is what
    # fails, and its message is the one the task reports. Modelling the
    # installed docker SDK 7.x instead rejected the host first and
    # reported "Invalid bind address format: port is required: tkvwva"
    # (issue #1635, kpg 000011-multi-docker_image-chaos).
    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build({"api_version" => "tkmfuf", "docker_host" => "tkvwva"})
    end
    error.message.must_equal("Error connecting: invalid version number 'tkmfuf'")
  end

  it "validates the TLS cert paths before the api_version parse" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    # Real's AnsibleDockerClientBase.__init__ builds the vendored TLSConfig
    # (get_connect_params) BEFORE it constructs the client whose
    # StrictVersion parse reports a bad api_version. TLSConfig refuses a
    # client cert/key pair whose files are not both regular files, so a
    # task pairing unusable paths with a bogus api_version reports the
    # paths (issue #1637, kpg 000008-multi-docker_network_info-chaos).
    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build({
        "api_version" => "wwudbt",
        "client_cert" => PluginSpecHelper.tmp_path("nope-cert.pem"),
        "client_key"  => PluginSpecHelper.tmp_path("nope-key.pem"),
        "tls"         => "true",
      })
    end
    error.message.must_equal("TLS config error: Path to a certificate and key files must be provided through the client_cert param. " \
                             "TLS configurations should map the Docker CLI client configurations. " \
                             "See https://docs.docker.com/engine/articles/https/ for API details.")

    # ...and an existing pair lets the api_version parse be the failure,
    # so the check does not reject usable TLS setups.
    cert = PluginSpecHelper.tmp_path("cert.pem")
    key = PluginSpecHelper.tmp_path("key.pem")
    File.write(cert, "")
    File.write(key, "")
    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build({
        "api_version" => "wwudbt",
        "client_cert" => cert,
        "client_key"  => key,
        "tls"         => "true",
      })
    end
    error.message.must_equal("Error connecting: invalid version number 'wwudbt'")
  end

  it "validates the docker_api_version alias too" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build({"docker_api_version" => "atoobk"})
    end
    error.message.must_equal("Error connecting: invalid version number 'atoobk'")
  end

  it "rejects values outside StrictVersion's grammar" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    ["1", "1.41.0.1"].each do |value|
      error = assert_raises(Krikri::DockerClientConfigError) do
        Krikri::PluginHelpers::DockerClient.build({"api_version" => value})
      end
      error.message.must_equal("Error connecting: invalid version number '#{value}'")
    end
  end

  it "fails a version below the SDK's own minimum" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build({"api_version" => "1.20"})
    end
    error.message.must_equal("Error connecting: API versions below 1.21 are no longer supported by this library.")
  end

  it "fails a version below the module's 1.25 minimum with the bare message" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build({"api_version" => "1.24"})
    end
    error.message.must_equal("Docker API version is 1.24. Minimum version required is 1.25.")
  end

  it "treats a prerelease of the SDK minimum as below it, like StrictVersion" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build({"api_version" => "1.21a1"})
    end
    error.message.must_equal("Error connecting: API versions below 1.21 are no longer supported by this library.")
  end

  it "fails a prerelease of a below-minimum version with the module minimum message" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build({"api_version" => "1.24a1"})
    end
    error.message.must_equal("Docker API version is 1.24a1. Minimum version required is 1.25.")
  end

  it "accepts a prerelease of the module minimum, like LooseVersion" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    # Live-verified: real 5.2.1 accepts 1.25a1/1.25b2/1.25.0 on a
    # docker_network_info task. LooseVersion's [1, 25, "a", 1] is a
    # longer list than [1, 25], so it sorts above it.
    Krikri::PluginHelpers::DockerClient.build({"api_version" => "1.25a1"})
    Krikri::PluginHelpers::DockerClient.build({"api_version" => "1.25b2"})
    Krikri::PluginHelpers::DockerClient.build({"api_version" => "1.25.0"})
  end

  it "accepts a supported api_version and the auto default" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    Krikri::PluginHelpers::DockerClient.build({"api_version" => "1.41"})
    Krikri::PluginHelpers::DockerClient.build({"api_version" => "AUTO"})
    Krikri::PluginHelpers::DockerClient.build({} of String => String)
  end

  it "validates the DOCKER_API_VERSION env fallback" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    original = ENV["DOCKER_API_VERSION"]?
    begin
      ENV["DOCKER_API_VERSION"] = "atoobk"
      error = assert_raises(Krikri::DockerClientConfigError) do
        Krikri::PluginHelpers::DockerClient.build({} of String => String)
      end
      error.message.must_equal("Error connecting: invalid version number 'atoobk'")
    ensure
      if original
        ENV["DOCKER_API_VERSION"] = original
      else
        ENV.delete("DOCKER_API_VERSION")
      end
    end
  end

  it "validates the task environment: overlay's DOCKER_API_VERSION" do
    skip "requests not importable under this host's python3" unless docker_gate_ready?

    error = assert_raises(Krikri::DockerClientConfigError) do
      Krikri::PluginHelpers::DockerClient.build(
        {"_environment" => %({"DOCKER_API_VERSION":"atoobk"})})
    end
    error.message.must_equal("Error connecting: invalid version number 'atoobk'")
  end
end
