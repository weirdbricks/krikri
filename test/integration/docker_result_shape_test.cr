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

# A throwaway config file under the spec scratch space - these specs never
# touch the machine's real ~/.docker/config.json.
def docker_login_config : String
  path = PluginSpecHelper.tmp_path("krikri-kp-dk-login-config.json")
  File.write(path, %({"auths": {"https://registry-1.docker.io/v1/": {"auth": "a3Jpa3JyaTpib2d1cw=="}}}))
  path
end

describe "docker result shape: docker_login" do
  serial!

  # real: {"changed": false, "login_result": {}, "failed": false} - real
  # deletes its `actions` list before exit_json, so nothing but changed
  # and login_result survives (and no msg at all).
  it "matches real's logout key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    config_path = docker_login_config
    result = PluginSpecHelper.run("docker_login", {
      "registry_url" => "https://registry-1.docker.io/v1/", "state" => "absent",
      "config_path" => config_path, "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    docker_shape_keys(result).must_equal(["changed", "login_result", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["login_result"].as_h.empty?.must_equal(true)
    result.as_h.has_key?("msg").must_equal(false)
    # the credentials really are gone
    JSON.parse(File.read(config_path))["auths"].as_h.empty?.must_equal(true)
  end

  it "matches real's already-logged-out key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    config_path = docker_login_config
    PluginSpecHelper.run("docker_login", {
      "registry_url" => "https://registry-1.docker.io/v1/", "state" => "absent",
      "config_path" => config_path, "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    result = PluginSpecHelper.run("docker_login", {
      "registry_url" => "https://registry-1.docker.io/v1/", "state" => "absent",
      "config_path" => config_path, "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    docker_shape_keys(result).must_equal(["changed", "login_result", "failed"])
    result["changed"].as_bool.must_equal(false)
  end

  it "matches real's bad-credentials failure key set and order" do
    result = PluginSpecHelper.run("docker_login", {
      "registry_url" => "https://registry-1.docker.io/v1/",
      "username" => "krikri", "password" => "bogus",
      "docker_host" => "unix:///nonexistent/krikri-kp-dk-no-such-#{Process.pid}.sock",
    })
    docker_shape_keys(result).must_equal(["failed", "msg", "changed", "exception"])
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Logging into https://registry-1.docker.io/v1/ for user krikri failed - ")
  end
end

# Only ever touches the krikri-kp-dk-* containers these specs create.
def remove_krikri_kp_dk_container(name : String) : Nil
  Process.run("podman", ["rm", "-f", name], output: Process::Redirect::Close, error: Process::Redirect::Close)
end

describe "docker result shape: docker_container" do
  serial!

  # A tiny local image; the specs only ever create krikri-kp-dk-* containers.
  CONTAINER_IMAGE = "docker.io/library/alpine:latest"

  # real: {"changed": true, "container": {<inspect>}, "failed": false} - the
  # inspect payload is the daemon's own, so its keys and their order are
  # the daemon's, passed straight through.
  it "matches real's create key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-c"
    remove_krikri_kp_dk_container(name)
    result = PluginSpecHelper.run("docker_container", {
      "name" => name, "image" => CONTAINER_IMAGE, "command" => "sleep 30",
      "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    docker_shape_keys(result).must_equal(["changed", "container", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["container"]["Name"].as_s.must_equal("/#{name}")
    docker_shape_keys(result["container"]).must_equal([
      "Id", "Created", "Path", "Args", "State", "Image", "ResolvConfPath",
      "HostnamePath", "HostsPath", "LogPath", "Name", "RestartCount",
      "Driver", "Platform", "MountLabel", "ProcessLabel", "AppArmorProfile",
      "ExecIDs", "HostConfig", "GraphDriver", "SizeRootFs", "Mounts",
      "Config", "NetworkSettings",
    ])
    result.as_h.has_key?("msg").must_equal(false)

    remove_krikri_kp_dk_container(name)
  end

  # real check_mode create: {"changed", "actions", "failed"} - one action
  # dict per operation, and no `container` (nothing was actually created).
  it "matches real's check_mode create key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-c2"
    remove_krikri_kp_dk_container(name)
    result = PluginSpecHelper.run_raw("docker_container",
      {"name" => JSON::Any.new(name), "image" => JSON::Any.new(CONTAINER_IMAGE),
       "command" => JSON::Any.new("sleep 30"), "docker_host" => JSON::Any.new(DOCKER_RESULT_SHAPE_SOCKET),
       "_ansible_check_mode" => JSON::Any.new(true)})
    docker_shape_keys(result).must_equal(["changed", "actions", "failed"])
    actions = result["actions"].as_a
    actions.size.must_equal(1)
    actions[0]["created"].as_s.must_equal("Created container")
    actions[0]["create_parameters"]["Cmd"].as_a.map(&.as_s).must_equal(["sleep", "30"])
    actions[0].as_h.has_key?("networks").must_equal(true)
    result.as_h.has_key?("container").must_equal(false)

    remove_krikri_kp_dk_container(name)
  end

  # real removal: {"changed": true, "failed": false} - state=absent records
  # no container facts at all
  it "matches real's removed key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-c3"
    remove_krikri_kp_dk_container(name)
    PluginSpecHelper.run("docker_container", {
      "name" => name, "image" => CONTAINER_IMAGE, "command" => "sleep 30",
      "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    result = PluginSpecHelper.run("docker_container", {
      "name" => name, "state" => "absent", "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    docker_shape_keys(result).must_equal(["changed", "failed"])
    result["changed"].as_bool.must_equal(true)
  end

  it "matches real's already-absent key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    result = PluginSpecHelper.run("docker_container", {
      "name" => "krikri-kp-dk-shape-gone", "state" => "absent",
      "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    docker_shape_keys(result).must_equal(["changed", "failed"])
    result["changed"].as_bool.must_equal(false)
  end

  it "matches real's missing-image failure key set and order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-c4"
    remove_krikri_kp_dk_container(name)
    result = PluginSpecHelper.run("docker_container", {
      "name" => name, "image" => "krikri-kp-dk-nosuchimage:9", "command" => "sleep 30",
      "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    docker_shape_keys(result).must_equal(["failed", "msg", "changed", "exception"])
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Error pulling image krikri-kp-dk-nosuchimage:9 - ")
    remove_krikri_kp_dk_container(name)
  end

  # real (community.docker 5.2.1, module.py's own fail_json): a task
  # that needs to create a container but named no image at all.
  it "fails a container-less create with real's own wording" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-noimage"
    remove_krikri_kp_dk_container(name)
    result = PluginSpecHelper.run("docker_container", {
      "name" => name, "command" => "sleep 30",
      "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Cannot create container when image is not specified!")
  end

  # real wraps a failed pull in its own prefix around the Docker Python
  # SDK's APIError text, which quotes the versioned pull URL (the `/` in
  # the repository percent-encoded) and the daemon's own message.
  it "reports a failed pull in real's own SDK wording" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-pull"
    remove_krikri_kp_dk_container(name)
    result = PluginSpecHelper.run("docker_container", {
      "name" => name, "image" => "kop.invalid/nope:1", "command" => "sleep 30",
      "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    result["failed"].as_bool.must_equal(true)
    msg = result["msg"].as_s
    msg.starts_with?("Error pulling image kop.invalid/nope:1 - ").must_equal(true, msg)
    msg.must_include("Server Error for http+docker://localhost/v")
    msg.must_include("/images/create?tag=1&fromImage=kop.invalid%2Fnope: ")
    # the daemon's own message, quoted, is the tail of real's rendering
    msg.ends_with?("\")").must_equal(true, msg)
    msg.wont_include("Code: ")
  end

  # real's create payload never carries StopSignal/StopTimeout unless
  # the task set stop_signal:/stop_timeout:, so the container it
  # registers has neither - `docr`'s own config defaults would show up
  # here as SIGTERM/10.
  it "creates a container whose Config sets neither StopSignal nor StopTimeout" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-stopcfg"
    remove_krikri_kp_dk_container(name)
    result = PluginSpecHelper.run("docker_container", {
      "name" => name, "image" => CONTAINER_IMAGE, "command" => "sleep 30",
      "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
    })
    result["changed"].as_bool.must_equal(true)
    config = result["container"]["Config"]
    # A Docker Engine daemon registers an empty StopSignal (and a null
    # StopTimeout) for a container real created; Podman's compat API
    # reports its own "15"/10 defaults either way, so the SIGTERM
    # spelling docr would have sent is what a regression guard can key
    # on here.
    config["StopSignal"].as_s.wont_include("SIGTERM")
    remove_krikri_kp_dk_container(name)
  end
end

# Real's check_mode create action records the create payload real would
# have sent: the argv list and stdio flags it always sets, plus a key per
# option the task actually gave - and no key at all for one it didn't
# (live-verified against 2.19.11 + community.docker 5.2.1: a plain
# create records only Cmd..OpenStdin, Image and ExposedPorts).
def docker_shape_create_payload(name : String, extra : Hash(String, JSON::Any)) : JSON::Any
  PluginSpecHelper.run_raw("docker_container",
    {"name" => JSON::Any.new(name), "image" => JSON::Any.new("docker.io/library/alpine:latest"),
     "command" => JSON::Any.new("sleep 30"), "docker_host" => JSON::Any.new(DOCKER_RESULT_SHAPE_SOCKET),
     "_ansible_check_mode" => JSON::Any.new(true)}.merge(extra))["actions"].as_a[0]["create_parameters"]
end

describe "docker result shape: docker_container check-mode create payload" do
  serial!

  it "records only the stdio flags, image and exposed ports for a plain create" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    remove_krikri_kp_dk_container("krikri-kp-dk-shape-cp-plain")
    payload = docker_shape_create_payload("krikri-kp-dk-shape-cp-plain", {} of String => JSON::Any)
    payload.as_h.keys.to_a.must_equal(
      ["Cmd", "AttachStdout", "AttachStderr", "AttachStdin", "StdinOnce", "OpenStdin", "Image", "ExposedPorts"])
    payload["ExposedPorts"].as_h.must_be_empty
  end

  it "records each given option under real's own key, in real's own order" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    remove_krikri_kp_dk_container("krikri-kp-dk-shape-cp-full")
    payload = docker_shape_create_payload("krikri-kp-dk-shape-cp-full", {
      "env"            => JSON::Any.new(%({"A":"b"})),
      "hostname"       => JSON::Any.new("kophost"),
      "labels"         => JSON::Any.new(%({"kop":"1"})),
      "restart_policy" => JSON::Any.new("unless-stopped"),
      "volumes"        => JSON::Any.new(%(["/tmp:/kop_tmp:ro"])),
      "ports"          => JSON::Any.new(%(["18080:80"])),
    })

    payload.as_h.keys.to_a.must_equal([
      "Cmd", "AttachStdout", "AttachStderr", "AttachStdin", "StdinOnce", "OpenStdin",
      "Env", "Hostname", "Image", "Labels", "HostConfig", "Volumes", "ExposedPorts",
    ])
    payload["Env"].as_a.map(&.as_s).must_equal(["A=b"])
    payload["Hostname"].as_s.must_equal("kophost")
    payload["Labels"].as_h.must_equal({"kop" => JSON::Any.new("1")})
    host_config = payload["HostConfig"]
    host_config.as_h.keys.to_a.must_equal(["RestartPolicy", "Binds", "PortBindings"])
    host_config["RestartPolicy"].as_h.must_equal({
      "Name" => JSON::Any.new("unless-stopped"), "MaximumRetryCount" => JSON::Any.new(nil),
    })
    host_config["Binds"].as_a.map(&.as_s).must_equal(["/tmp:/kop_tmp:ro"])
    host_config["PortBindings"]["80/tcp"].as_a.must_equal([
      {"HostIp" => JSON::Any.new("0.0.0.0"), "HostPort" => JSON::Any.new("18080")},
    ])
    payload["Volumes"].as_h.must_be_empty
    payload["ExposedPorts"].as_h.keys.to_a.must_equal(["80/tcp"])
    payload["ExposedPorts"]["80/tcp"].as_h.must_be_empty
  end

  # env: alone lands between OpenStdin and Image - the order real's own
  # option list gives it, not alphabetical order.
  it "puts a lone env: right after the stdio flags" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    remove_krikri_kp_dk_container("krikri-kp-dk-shape-cp-env")
    payload = docker_shape_create_payload("krikri-kp-dk-shape-cp-env", {"env" => JSON::Any.new(%({"Z":"y"}))})
    payload.as_h.keys.to_a.must_equal([
      "Cmd", "AttachStdout", "AttachStderr", "AttachStdin", "StdinOnce", "OpenStdin",
      "Env", "Image", "ExposedPorts",
    ])
    payload["Env"].as_a.map(&.as_s).must_equal(["Z=y"])
  end
end

# Real stops a RUNNING container before removing it for a recreate, and
# records that stop as its own action ahead of the removal; a container
# that is already stopped gets no stopped action at all.
def docker_shape_started(name : String) : JSON::Any
  PluginSpecHelper.run_raw("docker_container",
    {"name" => JSON::Any.new(name), "image" => JSON::Any.new("docker.io/library/alpine:latest"),
     "command" => JSON::Any.new("sleep 30"), "docker_host" => JSON::Any.new(DOCKER_RESULT_SHAPE_SOCKET)})
end

def docker_shape_recreate(name : String, env : String) : Array(JSON::Any)
  PluginSpecHelper.run_raw("docker_container",
    {"name" => JSON::Any.new(name), "image" => JSON::Any.new("docker.io/library/alpine:latest"),
     "env" => JSON::Any.new(env), "docker_host" => JSON::Any.new(DOCKER_RESULT_SHAPE_SOCKET),
     "_ansible_check_mode" => JSON::Any.new(true)})["actions"].as_a
end

describe "docker result shape: docker_container check-mode recreate" do
  serial!

  it "leads with real's stopped action for a running container" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-rec1"
    remove_krikri_kp_dk_container(name)
    begin
      container_id = docker_shape_started(name)["container"]["Id"].as_s
      actions = docker_shape_recreate(name, %({"DRIFTED":"1"}))
      actions.size.must_equal(3)
      actions[0].as_h.keys.to_a.must_equal(["stopped", "timeout"])
      actions[0]["stopped"].as_s.must_equal(container_id)
      # stop_timeout: has no default, so real records an explicit null
      actions[0]["timeout"].raw.must_be_nil
      actions[1].as_h.keys.to_a.must_equal(["removed", "volume_state", "link", "force"])
      actions[1]["removed"].as_s.must_equal(container_id)
      actions[2]["created"].as_s.must_equal("Created container")
    ensure
      remove_krikri_kp_dk_container(name)
    end
  end

  it "records no stopped action for an already stopped container" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-rec2"
    remove_krikri_kp_dk_container(name)
    begin
      PluginSpecHelper.run("docker_container", {
        "name" => name, "image" => "docker.io/library/alpine:latest", "command" => "sleep 30",
        "state" => "stopped", "docker_host" => DOCKER_RESULT_SHAPE_SOCKET,
      })
      actions = docker_shape_recreate(name, %({"DRIFTED":"1"}))
      actions.size.must_equal(2)
      actions[0].as_h.keys.to_a.must_equal(["removed", "volume_state", "link", "force"])
      actions[1]["created"].as_s.must_equal("Created container")
    ensure
      remove_krikri_kp_dk_container(name)
    end
  end
end

# real's env:/labels: are dict-typed options that real Ansible also
# accepts as a list of KEY=VALUE strings; an element containing a comma
# must survive as one entry (the parser JSON-encodes that list form - see
# the docker_container list branch in playbook_parser).
describe "docker result shape: docker_container list-form env" do
  serial!

  it "keeps a comma-carrying env element whole" do
    skip("no Docker-API socket at #{DOCKER_RESULT_SHAPE_SOCKET_PATH}") unless docker_shape_socket?
    name = "krikri-kp-dk-shape-envlist"
    remove_krikri_kp_dk_container(name)
    begin
      result = PluginSpecHelper.run_raw("docker_container",
        {"name" => JSON::Any.new(name), "image" => JSON::Any.new("docker.io/library/alpine:latest"),
         "command" => JSON::Any.new("sleep 30"), "env" => JSON::Any.new(%(["PLAIN=1","JSON=one,two"])),
         "labels" => JSON::Any.new(%(["pair=a,b"])),
         "docker_host" => JSON::Any.new(DOCKER_RESULT_SHAPE_SOCKET)})
      env = result["container"]["Config"]["Env"].as_a.map(&.as_s)
      env.must_include("PLAIN=1")
      env.must_include("JSON=one,two")
      result["container"]["Config"]["Labels"].as_h.must_equal({"pair" => JSON::Any.new("a,b")})
    ensure
      remove_krikri_kp_dk_container(name)
    end
  end
end

# The same registered-result SHAPE, reached through a list-valued
# `command:` (real's ansible-type `raw` option passes a YAML list to the
# daemon as the argv list) - the check_mode create action's Cmd must be
# the argv list itself, element for element, spaces included.
# Live-verified against 2.19.11 + community.docker 5.2.1 on the dk2
# podman socket; skips when it is not up.
DOCKER_SHAPE_CMD_SOCKET      = "unix:///tmp/krikri-kp-dk2.sock"
DOCKER_SHAPE_CMD_SOCKET_PATH = "/tmp/krikri-kp-dk2.sock"

describe "docker result shape: docker_container list command" do
  serial!

  it "matches real's create key set and order for a list command" do
    skip("no Docker-API socket at #{DOCKER_SHAPE_CMD_SOCKET_PATH}") unless File.exists?(DOCKER_SHAPE_CMD_SOCKET_PATH)
    name = "krikri-kp-dk2-shape-cmd"
    remove_krikri_kp_dk_container(name)
    result = PluginSpecHelper.run_raw("docker_container",
      {"name" => JSON::Any.new(name), "image" => JSON::Any.new("docker.io/library/alpine:latest"),
       "command" => JSON::Any.new("[\"sh\", \"-c\", \"echo hello world\"]"),
       "docker_host" => JSON::Any.new(DOCKER_SHAPE_CMD_SOCKET)})
    docker_shape_keys(result).must_equal(["changed", "container", "failed"])
    result["changed"].as_bool.must_equal(true)
    result["container"]["Config"]["Cmd"].as_a.map(&.as_s).must_equal(["sh", "-c", "echo hello world"])
    remove_krikri_kp_dk_container(name)
  end

  it "records real's argv list in the check_mode create action" do
    skip("no Docker-API socket at #{DOCKER_SHAPE_CMD_SOCKET_PATH}") unless File.exists?(DOCKER_SHAPE_CMD_SOCKET_PATH)
    result = PluginSpecHelper.run_raw("docker_container",
      {"name" => JSON::Any.new("krikri-kp-dk2-shape-cmd-cm"), "image" => JSON::Any.new("docker.io/library/alpine:latest"),
       "command" => JSON::Any.new("[\"sh\", \"-c\", \"echo hello world\"]"),
       "docker_host" => JSON::Any.new(DOCKER_SHAPE_CMD_SOCKET),
       "_ansible_check_mode" => JSON::Any.new(true)})
    docker_shape_keys(result).must_equal(["changed", "actions", "failed"])
    result["actions"].as_a[0]["create_parameters"]["Cmd"].as_a.map(&.as_s)
      .must_equal(["sh", "-c", "echo hello world"])
  end
end
