require "../spec_helper"

# Pins plugins/docker_network.cr + plugins/docker_network_info.cr's
# argument-validation surfaces against real community.docker's
# AnsibleModule setup (source-verified against docker_network.py /
# docker_network_info.py + _util.py DOCKER_COMMON_ARGS; live-diffed vs
# real ansible-playbook via the podman-diff docker_network_edge_cases +
# docker_network_info_edge_cases harnesses - real runs all of this
# BEFORE its eager daemon ping, the only byte-comparable surface
# without a daemon):
#
# - required name (docker_network_info has no aliases on it;
#   docker_network's is name (network_name))
# - state/scope choices render in declaration order
# - common args (DOCKER_COMMON_ARGS) type-convert too: timeout int,
#   tls/use_ssh_client/validate_certs/debug bool, labels
#   driver_options/ipam_driver_options dict
# - client_cert/client_key required-together (DOCKER_REQUIRED_TOGETHER)
# - ipam_config elements must be dicts, failing in the no_log pass with
#   the BARE check_type_dict wording (it has suboptions)
# - unsupported params: spec keys sorted, then ONE trailing
#   parenthetical holding every alias sorted (live-verified format)
describe "docker_network plugin argument validation" do
  it "fails without name" do
    result = PluginSpecHelper.run("docker_network", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "fails an invalid state choice in declaration order" do
    result = PluginSpecHelper.run("docker_network", {"name" => "krikri-net", "state" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, got: banana")
  end

  it "fails an invalid scope choice in declaration order" do
    result = PluginSpecHelper.run("docker_network", {"name" => "krikri-net", "scope" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of scope must be one of: local, global, swarm, got: banana")
  end

  it "fails a non-integer timeout (common arg)" do
    result = PluginSpecHelper.run("docker_network", {"name" => "krikri-net", "timeout" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("argument 'timeout' is of type <class 'str'> and we were unable to convert to int: <class 'str'> cannot be converted to an int")
  end

  it "fails a non-dict labels with the wrapped parameters.py wording" do
    result = PluginSpecHelper.run("docker_network", {"name" => "krikri-net", "labels" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("argument 'labels' is of type <class 'str'> and we were unable to convert to dict: " \
                                 "dictionary requested, could not parse JSON or key=value")
  end

  it "fails client_cert without client_key (required_together)" do
    result = PluginSpecHelper.run("docker_network", {"name" => "krikri-net", "client_cert" => "/tmp/cert.pem"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are required together: client_cert, client_key")
  end

  it "fails a plain-string ipam_config with the bare check_type_dict wording" do
    result = PluginSpecHelper.run("docker_network", {"name" => "krikri-net", "ipam_config" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("dictionary requested, could not parse JSON or key=value")
  end

  it "rejects unsupported parameters with the all-aliases parenthetical" do
    result = PluginSpecHelper.run("docker_network", {"name" => "krikri-net", "banana" => "x"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should start_with("Unsupported parameters for (community.docker.docker_network) module: banana. " \
                                         "Supported parameters include: api_version, appends, attachable, ca_path, client_cert, " \
                                         "client_key, config_from, config_only, connected, debug, docker_host, driver, " \
                                         "driver_options, enable_ipv4, enable_ipv6, force, ingress, internal, ipam_config, " \
                                         "ipam_driver, ipam_driver_options, labels, name, scope, state, timeout, tls, " \
                                         "tls_hostname, use_ssh_client, validate_certs (")
  end
end

describe "docker_network_info plugin argument validation" do
  it "fails without name" do
    result = PluginSpecHelper.run("docker_network_info", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "fails a non-integer timeout (common arg)" do
    result = PluginSpecHelper.run("docker_network_info", {"name" => "krikri-net", "timeout" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("argument 'timeout' is of type <class 'str'> and we were unable to convert to int: <class 'str'> cannot be converted to an int")
  end

  it "fails client_cert without client_key (required_together)" do
    result = PluginSpecHelper.run("docker_network_info", {"name" => "krikri-net", "client_cert" => "/tmp/cert.pem"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are required together: client_cert, client_key")
  end

  it "rejects unsupported parameters with the all-aliases parenthetical" do
    result = PluginSpecHelper.run("docker_network_info", {"name" => "krikri-net", "banana" => "x"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.docker.docker_network_info) module: banana. " \
                                 "Supported parameters include: api_version, ca_path, client_cert, client_key, debug, " \
                                 "docker_host, name, timeout, tls, tls_hostname, use_ssh_client, validate_certs " \
                                 "(ca_cert, cacert_path, cert_path, docker_api_version, docker_url, key_path, " \
                                 "tls_ca_cert, tls_client_cert, tls_client_key, tls_verify).")
  end
end
