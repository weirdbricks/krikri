require "../spec_helper"

# Pins plugins/docker_login.cr's argument-validation surface against real
# community.docker.docker_login's AnsibleModule setup (source-verified
# against the collection's docker_login.py + _util.py DOCKER_COMMON_ARGS;
# live-diffed vs real ansible-playbook via the podman-diff
# docker_login_edge_cases harness - real runs all of this BEFORE its
# eager daemon ping, the only byte-comparable surface without a daemon):
#
# - required_if (state, present, [username, password]) is key PRESENCE
# - state choices render in declaration order (present, absent)
# - common args (DOCKER_COMMON_ARGS) type-convert too: timeout int,
#   reauthorize bool
# - client_cert/client_key required-together (DOCKER_REQUIRED_TOGETHER)
# - unsupported params: spec keys sorted, then ONE trailing
#   parenthetical holding every alias sorted (live-verified format)
describe "docker_login plugin argument validation" do
  it "fails state=present without username and password (required_if)" do
    result = PluginSpecHelper.run("docker_login", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("state is present but all of the following are missing: username, password")
  end

  it "fails an invalid state choice in declaration order" do
    result = PluginSpecHelper.run("docker_login", {
      "username" => "krikri",
      "password" => "sekret",
      "state"    => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, got: banana")
  end

  it "fails a non-integer timeout (common arg)" do
    result = PluginSpecHelper.run("docker_login", {
      "username" => "krikri",
      "password" => "sekret",
      "timeout"  => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("argument 'timeout' is of type <class 'str'> and we were unable to convert to int: <class 'str'> cannot be converted to an int")
  end

  it "fails a non-boolean reauthorize with parameters.py wording" do
    result = PluginSpecHelper.run("docker_login", {
      "username"    => "krikri",
      "password"    => "sekret",
      "reauthorize" => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'reauthorize' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'banana' is not a valid boolean.  Valid booleans include: ")
  end

  it "fails client_cert without client_key (required_together)" do
    result = PluginSpecHelper.run("docker_login", {
      "username"    => "krikri",
      "password"    => "sekret",
      "client_cert" => "/tmp/cert.pem",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are required together: client_cert, client_key")
  end

  it "rejects unsupported parameters with the all-aliases parenthetical" do
    result = PluginSpecHelper.run("docker_login", {
      "username" => "krikri",
      "password" => "sekret",
      "banana"   => "x",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.docker.docker_login) module: banana. " \
                                 "Supported parameters include: api_version, ca_path, client_cert, client_key, " \
                                 "config_path, debug, docker_host, password, reauthorize, registry_url, state, " \
                                 "timeout, tls, tls_hostname, use_ssh_client, username, validate_certs " \
                                 "(ca_cert, cacert_path, cert_path, docker_api_version, docker_url, dockercfg_path, " \
                                 "key_path, reauth, registry, tls_ca_cert, tls_client_cert, tls_client_key, tls_verify, url).")
  end

  it "state=absent needs no credentials (no required_if)" do
    result = PluginSpecHelper.run("docker_login", {"state" => "absent"})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("not present, doing nothing")
  end
end
