require "../minitest_helper"

# community.docker.docker_container state=healthy - the health-wait
# phase added on top of the started flow (see
# PluginHelpers::DockerHealthWait). Uses a real Docker daemon (the
# local podman-backed shim works too) and skips when none is reachable,
# same convention as the other daemon-dependent plugin specs.
describe "docker_container state=healthy" do
  def daemon_reachable?
    probe = PluginSpecHelper.run("docker_container", {
      "name"  => "krikri-hc-probe-#{Process.pid}",
      "state" => "absent",
      "image" => "busybox:latest",
    })
    !(probe["msg"]?.try(&.as_s).to_s.includes?("Could not connect to the Docker daemon"))
  end

  it "fails when name is missing" do
    result = PluginSpecHelper.run("docker_container", {} of String => String)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("missing required argument: name")
  end

  it "reports real's type error for a non-numeric healthy_wait_timeout" do
    result = PluginSpecHelper.run("docker_container", {
      "name"                 => "krikri-hc-badt-#{Process.pid}",
      "image"                => "busybox:latest",
      "state"                => "stopped",
      "healthy_wait_timeout" => "bogus",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "argument 'healthy_wait_timeout' is of type str and we were unable to convert to float: " \
      "<class 'str'> cannot be converted to a float")
  end

  it "succeeds immediately for a container with no healthcheck and returns container facts" do
    skip("no reachable docker daemon") unless daemon_reachable?
    name = "krikri-hc-nohc-#{Process.pid}"
    begin
      result = PluginSpecHelper.run("docker_container", {
        "name"    => name,
        "image"   => "busybox:latest",
        "state"   => "healthy",
        "command" => "top",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["container"].as_h["Name"].as_s.must_equal("/#{name}")
      result["container"].as_h["State"].as_h["Health"]?.must_be_nil
    ensure
      PluginSpecHelper.run("docker_container", {"name" => name, "state" => "absent"})
    end
  end

  it "waits for a passing healthcheck to report healthy" do
    skip("no reachable docker daemon") unless daemon_reachable?
    name = "krikri-hc-ok-#{Process.pid}"
    begin
      result = PluginSpecHelper.run("docker_container", {
        "name"        => name,
        "image"       => "busybox:latest",
        "state"       => "healthy",
        "command"     => "top",
        "healthcheck" => %({"test": ["CMD-SHELL", "true"], "interval": "1s", "timeout": "1s", "retries": 2}),
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["container"].as_h["State"].as_h["Health"].as_h["Status"].as_s.must_equal("healthy")
    ensure
      PluginSpecHelper.run("docker_container", {"name" => name, "state" => "absent"})
    end
  end

  it "fails with real's timeout wording when the healthcheck never turns healthy" do
    skip("no reachable docker daemon") unless daemon_reachable?
    name = "krikri-hc-fail-#{Process.pid}"
    begin
      result = PluginSpecHelper.run("docker_container", {
        "name"                 => name,
        "image"                => "busybox:latest",
        "state"                => "healthy",
        "command"              => "top",
        "healthy_wait_timeout" => "5",
        "healthcheck"          => %({"test": ["CMD-SHELL", "false"], "interval": "1s", "timeout": "1s", "retries": 1}),
      })
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_match(/Timeout of 5\.0 seconds exceeded while waiting for container "[0-9a-f]{64}"/)
      result["container"].as_h["State"].as_h["Health"].as_h["Status"].as_s.must_equal("unhealthy")
    ensure
      PluginSpecHelper.run("docker_container", {"name" => name, "state" => "absent"})
    end
  end

  it "skips the health wait in check mode" do
    skip("no reachable docker daemon") unless daemon_reachable?
    name = "krikri-hc-check-#{Process.pid}"
    begin
      result = PluginSpecHelper.run("docker_container", {
        "name"                => name,
        "image"               => "busybox:latest",
        "state"               => "healthy",
        "command"             => "top",
        "_ansible_check_mode" => "true",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("would be created and started")
      result["container"]?.must_be_nil
    ensure
      PluginSpecHelper.run("docker_container", {"name" => name, "state" => "absent"})
    end
  end
end
