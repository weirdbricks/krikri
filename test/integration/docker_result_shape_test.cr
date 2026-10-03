require "../minitest_helper"

# Registered-result shape parity for the community.docker plugins,
# live-verified key-for-key against real ansible-core 2.19.11 +
# community.docker 5.2.1 driving a Docker-API socket.
#
# Real's registered result is the module's own dict in ITS insertion
# order (exit_json kwargs first, then the module's result dict), which
# PluginResult#key_order reproduces - see plugins/command.cr's
# SUCCESS_KEY_ORDER and test/integration/key_order_sweep*_test.cr.
#
# Every spec here talks to the SAME runtime through that socket, so they
# serialize on the shared state mutex.
#
# The socket is a podman `system service` endpoint
# (`podman system service --time=0 unix:///tmp/krikri-kp-dk.sock`); the
# specs skip when it is not up. Nothing here creates a container,
# network or image outside the krikri-kp-dk- prefix.
DOCKER_RESULT_SHAPE_SOCKET = "unix:///tmp/krikri-kp-dk.sock"

def docker_shape_params(name : String, extra : Hash(String, String) = {} of String => String) : Hash(String, String)
  {"name" => name, "docker_host" => DOCKER_RESULT_SHAPE_SOCKET}.merge(extra)
end

DOCKER_RESULT_SHAPE_SOCKET_PATH = "/tmp/krikri-kp-dk.sock"

# `skip` is the spec DSL's own method, so it can only be called from
# inside an `it` block - each spec guards itself.
def docker_shape_socket? : Bool
  File.exists?(DOCKER_RESULT_SHAPE_SOCKET_PATH)
end

def docker_shape_keys(result : JSON::Any) : Array(String)
  result.as_h.keys.to_a
end

describe "docker result shape: docker_network" do
  serial!

  # real: {"changed": true, "network": {...inspect...}, "failed": false}
  # (present() pops `actions` again once a real run finishes)
  it "matches real's create key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    result = PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n"))
    docker_shape_keys(result).must_equal(["changed", "network", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["failed"].as_bool.must_equal(false)
    # `network` is the daemon's raw inspect payload, passed through
    # verbatim - same keys and same order real registers.
    docker_shape_keys(result["network"]).must_equal([
      "Name", "Id", "Created", "Scope", "Driver", "EnableIPv6", "IPAM",
      "Internal", "Attachable", "Ingress", "ConfigFrom", "ConfigOnly",
      "Containers", "Options", "Labels",
    ])
    result["network"]["Name"].as_s.must_equal("krikri-kp-dk-shape-n")
    result["network"]["Driver"].as_s.must_equal("bridge")

    PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n", {"state" => "absent"}))
  end

  it "matches real's unchanged rerun key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n2"))
    result = PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n2"))
    docker_shape_keys(result).must_equal(["changed", "network", "failed"])
    result["changed"].as_bool.must_equal(false)

    PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n2", {"state" => "absent"}))
  end

  # real check_mode create: {"changed", "actions", "network", "diff", "failed"}
  it "matches real's check_mode create key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    result = PluginSpecHelper.run_raw("docker_network",
      {"name" => JSON::Any.new("krikri-kp-dk-shape-n3"), "docker_host" => JSON::Any.new(DOCKER_RESULT_SHAPE_SOCKET), "_ansible_check_mode" => JSON::Any.new(true)})
    docker_shape_keys(result).must_equal(["changed", "actions", "network", "diff", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["actions"].as_a.map(&.as_s).must_equal(["Created network krikri-kp-dk-shape-n3 with driver bridge"])
    # nothing was actually created, so `network` is real's null
    result["network"].raw.must_be_nil
    result["diff"]["differences"].as_a.size.must_equal(0)
    # check_mode created nothing, so removing it is a no-op too
    PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n3", {"state" => "absent"}))
  end

  # real removed: {"changed": true, "actions": ["Removed network X"], "failed": false}
  it "matches real's removed key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n4"))
    result = PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n4", {"state" => "absent"}))
    docker_shape_keys(result).must_equal(["changed", "actions", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["actions"].as_a.map(&.as_s).must_equal(["Removed network krikri-kp-dk-shape-n4"])
  end

  # real already-absent: {"changed": false, "actions": [], "failed": false}
  it "matches real's already-absent key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    result = PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-absent", {"state" => "absent"}))
    docker_shape_keys(result).must_equal(["changed", "actions", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["actions"].as_a.must_be_empty
  end

  # real check_mode removal: {"changed", "actions", "diff", "failed"} -
  # the absent path records an EMPTY diff dict in check_mode
  it "matches real's check_mode removal key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n5"))
    result = PluginSpecHelper.run_raw("docker_network",
      {"name" => JSON::Any.new("krikri-kp-dk-shape-n5"), "docker_host" => JSON::Any.new(DOCKER_RESULT_SHAPE_SOCKET),
       "state" => JSON::Any.new("absent"), "_ansible_check_mode" => JSON::Any.new(true)})
    docker_shape_keys(result).must_equal(["changed", "actions", "diff", "failed"])
    result["changed"].as_bool.must_equal(true)
    # still there - check_mode removed nothing
    PluginSpecHelper.run("docker_network", docker_shape_params("krikri-kp-dk-shape-n5", {"state" => "absent"}))
  end

  # real: {"failed", "msg", "changed", "exception"}
  it "matches real's failure key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    result = PluginSpecHelper.run("docker_network",
      docker_shape_params("krikri-kp-dk-shape-n6", {"driver" => "nosuchdriver"}))
    docker_shape_keys(result).must_equal(["failed", "msg", "changed", "exception"])
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_include("An unexpected Docker error occurred:")
  end
end
describe "docker result shape: docker_network_info" do
  serial!

  # real: {"changed": false, "exists": false, "network": null, "failed": false}
  # (exit_json kwargs changed=, exists=, network=; no msg at all)
  it "matches real's not-found key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    result = PluginSpecHelper.run("docker_network_info",
      {"name" => "krikri-kp-dk-shape-ni-absent", "docker_host" => DOCKER_RESULT_SHAPE_SOCKET})
    docker_shape_keys(result).must_equal(["changed", "exists", "network", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["exists"].as_bool.must_equal(false)
    result["network"].raw.must_be_nil
    # no msg key on a successful info result
    result.as_h.has_key?("msg").must_equal(false)
  end

  it "matches real's found key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-ni"
    PluginSpecHelper.run("docker_network", docker_shape_params(name))
    result = PluginSpecHelper.run("docker_network_info",
      {"name" => name, "docker_host" => DOCKER_RESULT_SHAPE_SOCKET})
    docker_shape_keys(result).must_equal(["changed", "exists", "network", "failed"])
    result["exists"].as_bool.must_equal(true)
    result["network"]["Name"].as_s.must_equal(name)
    result.as_h.has_key?("msg").must_equal(false)

    PluginSpecHelper.run("docker_network", docker_shape_params(name, {"state" => "absent"}))
  end

  it "matches real's failure key set and order" do
    result = PluginSpecHelper.run("docker_network_info", {} of String => String)
    docker_shape_keys(result).must_equal(["failed", "msg", "changed", "exception"])
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("missing required arguments: name")
  end
end

# A tiny local image, re-tagged under the krikri-kp-dk- prefix so the
# specs below can exercise the present/absent paths without a registry
# and without touching any image the machine already had.
module DockerImageShapeSpec
  SOURCE = "docker.io/library/alpine:latest"
  REF    = "docker.io/library/krikri-kp-dk-img"

  def self.tag_image : Nil
    Process.run("podman", ["tag", SOURCE, "#{REF}:1"], output: Process::Redirect::Close)
  end

  def self.untag_image : Nil
    Process.run("podman", ["rmi", "#{REF}:1"], output: Process::Redirect::Close, error: Process::Redirect::Close)
  end
end

describe "docker result shape: docker_image" do
  serial!

  # The daemon only resolves a fully-qualified reference, so the specs
  # below tag a tiny local image under the krikri-kp-dk- prefix rather
  # than reaching for a registry.
  # real: {"changed": false, "actions": [], "image": {<inspect>}, "failed": false}
  it "matches real's present key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    DockerImageShapeSpec.tag_image
    result = PluginSpecHelper.run("docker_image",
      {"name" => "krikri-kp-dk-img", "tag" => "1", "source" => "local", "docker_host" => DOCKER_RESULT_SHAPE_SOCKET})
    docker_shape_keys(result).must_equal(["changed", "actions", "image", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["actions"].as_a.must_be_empty
    # `image` is the daemon's own inspect dict, verbatim
    result["image"]["Id"].as_s.must_include("sha256:")
    result["image"]["RepoTags"].as_a.map(&.as_s).must_include("docker.io/library/krikri-kp-dk-img:1")
    result.as_h.has_key?("msg").must_equal(false)

    DockerImageShapeSpec.untag_image
  end

  # real check_mode pull: {"changed": true, "actions": ["Pulled image X:1"], "image": {}, "failed": false}
  it "matches real's check_mode pull key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    result = PluginSpecHelper.run_raw("docker_image",
      {"name" => JSON::Any.new("krikri-kp-dk-img-cm"), "tag" => JSON::Any.new("1"),
       "source" => JSON::Any.new("pull"), "docker_host" => JSON::Any.new(DOCKER_RESULT_SHAPE_SOCKET),
       "_ansible_check_mode" => JSON::Any.new(true)})
    docker_shape_keys(result).must_equal(["changed", "actions", "image", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["actions"].as_a.map(&.as_s).must_equal(["Pulled image krikri-kp-dk-img-cm:1"])
    # nothing was pulled, so `image` is real's seeded empty dict
    result["image"].as_h.empty?.must_equal(true)
  end

  # real removed: {"changed": true, "actions": ["Removed image X:1"], "image": {"state": "Deleted"}, "failed": false}
  it "matches real's removed key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    DockerImageShapeSpec.tag_image
    result = PluginSpecHelper.run("docker_image",
      {"name" => "krikri-kp-dk-img", "tag" => "1", "state" => "absent", "docker_host" => DOCKER_RESULT_SHAPE_SOCKET})
    docker_shape_keys(result).must_equal(["changed", "actions", "image", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["actions"].as_a.map(&.as_s).must_equal(["Removed image krikri-kp-dk-img:1"])
    result["image"]["state"].as_s.must_equal("Deleted")
  end

  it "matches real's already-absent key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    result = PluginSpecHelper.run("docker_image",
      {"name" => "krikri-kp-dk-img", "tag" => "1", "state" => "absent", "docker_host" => DOCKER_RESULT_SHAPE_SOCKET})
    docker_shape_keys(result).must_equal(["changed", "actions", "image", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["actions"].as_a.must_be_empty
    result["image"].as_h.empty?.must_equal(true)
  end

  it "matches real's missing-image failure key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    result = PluginSpecHelper.run("docker_image",
      {"name" => "krikri-kp-dk-nope", "tag" => "9", "source" => "local", "docker_host" => DOCKER_RESULT_SHAPE_SOCKET})
    docker_shape_keys(result).must_equal(["failed", "msg", "changed", "exception"])
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Cannot find the image krikri-kp-dk-nope:9 locally.")
  end
end
