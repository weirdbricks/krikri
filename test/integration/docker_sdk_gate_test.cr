require "../minitest_helper"
require "file_utils"

# Plugin-level Docker SDK import gate: the five SDK-based community.docker
# modules krikri implements (docker_container, docker_image, docker_network,
# docker_network_info, docker_login) must fail with the collection's
# client-construction import wording (docker_client.cr's sdk_import_gate)
# BEFORE any daemon contact, and must be untouched when the gate passes.
#
# community.docker 5.2.1's five modules import the collection's VENDORED
# SDK, so the gate is `requests` (live-probed with the pinned pair
# ansible-core 2.19.11 + 5.2.1: a python3-docker-less interpreter runs
# docker_network fine; the docker>=5.0.0 wording belongs to the
# out-of-scope docker_swarm family via module_utils/_common.py).
#
# The failure branch is forced deterministically the same way
# deb822_repository's gate spec does it: a stub `requests` package on
# PYTHONPATH whose __init__ raises ImportError, which precedes
# site-packages in sys.path, so the probe `import requests` fails on every
# host. The env reaches the probe because the plugin spawns python with an
# inherited environment.
#
# The daemon contact is proven absent by pointing docker_host at a socket
# path that does not exist: with the gate firing, the failure is the import
# wording; when it passes, the SAME params produce the daemon's connect
# wording instead (no live daemon needed either way).
require "../../src/krikri/plugin_helpers/python_lib_gate"

GATE_SDK_MODULES = ["docker_container", "docker_image", "docker_network", "docker_network_info", "docker_login"]

private def gate_params(module_name : String) : Hash(String, String)
  base = {"docker_host" => "unix:///tmp/krikri-dk-gate-no-such.sock"} of String => String
  case module_name
  when "docker_container" then base.merge({"name" => "krikri-dk-gate-c", "image" => "busybox:latest"})
  when "docker_image"     then base.merge({"name" => "krikri-dk-gate-i", "source" => "pull"})
  when "docker_login"     then base.merge({"username" => "gate", "password" => "gate"})
  else                         base.merge({"name" => "krikri-dk-gate-n"})
  end
end

private def stub_requests_root(kind : String) : String
  stub_root = PluginSpecHelper.tmp_path("requests-gate-stub-#{kind}")
  FileUtils.rm_rf(stub_root)
  FileUtils.mkdir_p(File.join(stub_root, "requests"))
  File.write(File.join(stub_root, "requests", "__init__.py"),
    "raise ImportError(\"No module named 'requests'\")\n")
  stub_root
end

describe "docker sdk gate at plugin level" do
  serial!

  it "fails every SDK-based module with the exact import wording before any daemon contact" do
    stub_root = stub_requests_root("missing")
    python = Krikri.target_python_executable
    skip "no python on this host (the gate needs an interpreter to fail)" unless python
    expected = Krikri.missing_required_lib_message("requests", python)

    GATE_SDK_MODULES.each do |module_name|
      result = PluginSpecHelper.run(module_name, gate_params(module_name),
        env: {"PYTHONPATH" => stub_root})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(expected)
    end
  end

  it "gates docker_login's logout path too (real constructs its client before LoginManager)" do
    stub_root = stub_requests_root("missing")
    python = Krikri.target_python_executable
    skip "no python on this host (the gate needs an interpreter to fail)" unless python

    result = PluginSpecHelper.run("docker_login",
      {"state" => "absent", "docker_host" => "unix:///tmp/krikri-dk-gate-no-such.sock"},
      env: {"PYTHONPATH" => stub_root})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(Krikri.missing_required_lib_message("requests", python))
  end

  it "lets a passing gate through: the same params fail with the daemon connect wording, not the gate" do
    GATE_SDK_MODULES.each do |module_name|
      result = PluginSpecHelper.run(module_name, gate_params(module_name))

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("Error connecting")
      result["msg"].as_s.includes?("Failed to import the required Python library").must_equal(false)
    end
  end
end
