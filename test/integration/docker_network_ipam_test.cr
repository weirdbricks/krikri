require "../minitest_helper"

# docker_network ipam_config parity (subnet/iprange/gateway/aux_addresses),
# live-verified against ansible-core 2.19.11 + community.docker 5.2.1
# driving a podman docker-compatible socket:
#
# - a fully-specified pool creates with the real create payload (Subnet/
#   IPRange/Gateway/AuxiliaryAddresses, every key present) and re-creates
#   on every run there, because podman's readback echoes only Gateway and
#   Subnet - real does exactly the same (its has_different_config counts
#   iprange/aux_addresses as drift against the empty readback), so the
#   parity claim is the recreate DECISION and its actions/diff, not
#   idempotency
# - a subnet-only pool IS idempotent on podman (subnet matches the
#   readback, the null keys are skipped) - real reports changed=false too
# - the check_mode drift diff carries real's registered shape: legacy
#   `differences` names ("ipam_config[0].<key>"), then before/after with
#   `exists` leading both maps (captured via r | dict2items on real)
# - the subnet CIDR validation and the missing-subnet failure happen
#   AFTER the daemon connection (real's TaskParameters order), so both
#   need a live daemon to be byte-comparable
#
# The socket is a podman `system service` endpoint
# (`podman system service --time=0 unix:///tmp/krikri-kp-dk.sock`); the
# specs skip when it is not up. Everything here is scoped to the
# krikri-kp-dk-ipam- name prefix and removed again.
DOCKER_IPAM_SOCKET      = "unix:///tmp/krikri-kp-dk.sock"
DOCKER_IPAM_SOCKET_PATH = "/tmp/krikri-kp-dk.sock"

def docker_ipam_params(name : String, extra : Hash(String, String) = {} of String => String) : Hash(String, String)
  {"name" => name, "docker_host" => DOCKER_IPAM_SOCKET}.merge(extra)
end

def docker_ipam_socket? : Bool
  File.exists?(DOCKER_IPAM_SOCKET_PATH)
end

FULL_POOL = %([{"subnet": "10.99.70.0/24", "iprange": "10.99.70.0/25", "gateway": "10.99.70.1", "aux_addresses": {"host1": "10.99.70.5"}}])

describe "docker_network ipam_config" do
  serial!

  it "creates a fully-specified pool with the daemon-side IPAM applied" do
    skip("no Docker-API socket at #{DOCKER_IPAM_SOCKET_PATH}") unless docker_ipam_socket?
    name = "krikri-kp-dk-ipam-create"
    result = PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"ipam_config" => FULL_POOL}))

    result["changed"].as_bool.must_equal(true)
    ipam = result["network"]["IPAM"]
    config = ipam["Config"].as_a.first
    config["Subnet"].as_s.must_equal("10.99.70.0/24")
    config["Gateway"].as_s.must_equal("10.99.70.1")

    PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"state" => "absent"}))
  end

  it "re-creates a fully-specified pool on rerun, exactly like real against podman's readback" do
    skip("no Docker-API socket at #{DOCKER_IPAM_SOCKET_PATH}") unless docker_ipam_socket?
    name = "krikri-kp-dk-ipam-rerun"
    PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"ipam_config" => FULL_POOL}))
    result = PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"ipam_config" => FULL_POOL}))

    # A real (non-check_mode) run pops `actions` before registering, so
    # the recreate itself only shows as changed: true - the check_mode
    # spec below captures the Removed/Created action pair.
    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal(["changed", "network", "failed"])

    PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"state" => "absent"}))
  end

  it "leaves a subnet-only pool idempotent on rerun (readback covers every non-null key)" do
    skip("no Docker-API socket at #{DOCKER_IPAM_SOCKET_PATH}") unless docker_ipam_socket?
    name = "krikri-kp-dk-ipam-subnet"
    subnet_only = %([{"subnet": "10.99.71.0/24"}])
    PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"ipam_config" => subnet_only}))
    result = PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"ipam_config" => subnet_only}))

    result["changed"].as_bool.must_equal(false)

    PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"state" => "absent"}))
  end

  it "reports real's check_mode drift diff (differences + exists-led before/after)" do
    skip("no Docker-API socket at #{DOCKER_IPAM_SOCKET_PATH}") unless docker_ipam_socket?
    name = "krikri-kp-dk-ipam-diff"
    PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"ipam_config" => FULL_POOL}))
    result = PluginSpecHelper.run_raw("docker_network", {
      "name"                => JSON::Any.new(name),
      "docker_host"         => JSON::Any.new(DOCKER_IPAM_SOCKET),
      "ipam_config"         => JSON::Any.new(FULL_POOL),
      "_ansible_check_mode" => JSON::Any.new(true),
      "_ansible_diff"       => JSON::Any.new(true),
    })

    result["changed"].as_bool.must_equal(true)
    result["actions"].as_a.map(&.as_s).must_equal([
      "Removed network #{name}",
      "Created network #{name} with driver bridge",
    ])
    result.as_h.keys.must_equal(["changed", "actions", "network", "diff", "failed"])
    diff = result["diff"]
    diff["differences"].as_a.map(&.as_s).must_equal([
      "ipam_config[0].subnet", "ipam_config[0].iprange", "ipam_config[0].gateway", "ipam_config[0].aux_addresses",
    ])
    before = diff["before"]
    after = diff["after"]
    before.as_h.keys.must_equal(["exists", "ipam_config[0].subnet", "ipam_config[0].iprange", "ipam_config[0].gateway", "ipam_config[0].aux_addresses"])
    before["exists"].as_bool.must_equal(true)
    before["ipam_config[0].subnet"].raw.must_be_nil
    before["ipam_config[0].gateway"].raw.must_be_nil
    after["exists"].as_bool.must_equal(true)
    after["ipam_config[0].subnet"].as_s.must_equal("10.99.70.0/24")
    after["ipam_config[0].gateway"].as_s.must_equal("10.99.70.1")
    after["ipam_config[0].aux_addresses"].as_h["host1"].as_s.must_equal("10.99.70.5")

    PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"state" => "absent"}))
  end

  it "reports real's check_mode create diff (empty differences, exists false -> true)" do
    skip("no Docker-API socket at #{DOCKER_IPAM_SOCKET_PATH}") unless docker_ipam_socket?
    name = "krikri-kp-dk-ipam-cdiff"
    result = PluginSpecHelper.run_raw("docker_network", {
      "name"                => JSON::Any.new(name),
      "docker_host"         => JSON::Any.new(DOCKER_IPAM_SOCKET),
      "ipam_config"         => JSON::Any.new(%([{"subnet": "10.99.72.0/24"}])),
      "_ansible_check_mode" => JSON::Any.new(true),
      "_ansible_diff"       => JSON::Any.new(true),
    })

    diff = result["diff"]
    diff["differences"].as_a.must_be_empty
    diff["before"]["exists"].as_bool.must_equal(false)
    diff["after"]["exists"].as_bool.must_equal(true)
  end

  it "fails an invalid subnet CIDR with real's wording" do
    skip("no Docker-API socket at #{DOCKER_IPAM_SOCKET_PATH}") unless docker_ipam_socket?
    result = PluginSpecHelper.run("docker_network", docker_ipam_params("krikri-kp-dk-ipam-badcidr",
      {"ipam_config" => %([{"subnet": "10.99.0.0/33"}])}))

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(%("10.99.0.0/33" is not a valid CIDR))
  end

  it "fails a pool without a subnet with real's re.match(None) TypeError text" do
    skip("no Docker-API socket at #{DOCKER_IPAM_SOCKET_PATH}") unless docker_ipam_socket?
    result = PluginSpecHelper.run("docker_network", docker_ipam_params("krikri-kp-dk-ipam-nosubnet",
      {"ipam_config" => %([{"gateway": "10.99.5.1"}])}))

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("expected string or bytes-like object, got 'NoneType'")
  end
end

describe "docker_network ipam_driver passthrough" do
  serial!

  it "creates with the requested IPAM driver and treats a matching readback as converged" do
    skip("no Docker-API socket at #{DOCKER_IPAM_SOCKET_PATH}") unless docker_ipam_socket?
    name = "krikri-kp-dk-ipam-driver"
    result = PluginSpecHelper.run("docker_network", docker_ipam_params(name,
      {"ipam_driver" => "default", "ipam_config" => %([{"subnet": "10.99.73.0/24"}])}))

    result["changed"].as_bool.must_equal(true)
    result["network"]["IPAM"]["Driver"].as_s.must_equal("default")

    # podman's readback echoes Driver "default" - same comparison real
    # makes, so the rerun converges.
    rerun = PluginSpecHelper.run("docker_network", docker_ipam_params(name,
      {"ipam_driver" => "default", "ipam_config" => %([{"subnet": "10.99.73.0/24"}])}))
    rerun["changed"].as_bool.must_equal(false)

    PluginSpecHelper.run("docker_network", docker_ipam_params(name, {"state" => "absent"}))
  end
end
