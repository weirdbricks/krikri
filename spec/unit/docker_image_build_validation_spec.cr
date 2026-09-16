require "../spec_helper"

# Pins plugins/docker_image_build.cr's argument-validation surface against
# real community.docker.docker_image_build's AnsibleModule setup
# (source-verified against the collection's docker_image_build.py +
# ansible-core 2.14's arg_spec.ArgumentSpecValidator.validate order; the
# podman-diff docker_image_build_edge_cases harness ran every case against
# real ansible-playbook in a throwaway container):
#
# - required name+path render together, sorted ("missing required
#   arguments: name, path") - krikri previously failed one-param-at-a-time
#   with its own "Missing required parameter: name" wording, and checked
#   the path directory BEFORE any of the argument-spec validation, so an
#   invalid rebuild/pull/secret reported the path error instead
# - _list_no_log_values runs FIRST and itself fails a non-dict
#   secrets/outputs element with bare check_type_dict wording
#   ("dictionary requested, could not parse JSON or key=value")
# - sub-spec validation (secrets/outputs): required id/type, type choices
#   in declaration order, required_if ("type is value but all of the
#   following are missing: value"), mutually_exclusive ("parameters are
#   mutually exclusive: src|env|value") - each suffixed " found in
#   secrets"/" found in outputs"
# - secrets[].value is no_log: its value is blanked to 8 asterisks
#   everywhere in the final message, including inside ordinary words
#   (real B11: "mutually exclusi********e: src|en********|********alue")
# - pull/nocache are bool-converted with parameters.py's wording; the
#   Valid-booleans list order is a Python set iteration in real
#   (differs between processes), so only the wording shape is pinned
describe "docker_image_build plugin argument validation" do
  it "lists both missing required arguments, sorted" do
    result = PluginSpecHelper.run("docker_image_build", {"tag" => "latest"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name, path")
  end

  it "reports missing name alone when path is present" do
    result = PluginSpecHelper.run("docker_image_build", {"path" => "/tmp/krikri-build"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "fails an invalid rebuild choice before the path check" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "rebuild" => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of rebuild must be one of: never, always, got: banana")
  end

  it "fails a non-boolean pull with parameters.py wording" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name" => "krikri/test",
      "path" => "/tmp/krikri-no-such-dir",
      "pull" => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'pull' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'banana' is not a valid boolean.  Valid booleans include: ")
  end

  it "fails a non-boolean nocache with parameters.py wording" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "nocache" => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'nocache' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'banana' is not a valid boolean.")
  end

  it "fails a secret missing its required type" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "secrets" => %([{"id": "mysecret"}]),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: type found in secrets")
  end

  it "fails a secret missing its required id" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "secrets" => %([{"type": "file"}]),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: id found in secrets")
  end

  it "fails an invalid secret type choice" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "secrets" => %([{"id": "mysecret", "type": "banana"}]),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of type must be one of: file, env, value, got: banana found in secrets")
  end

  it "fails type=value without value via required_if" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "secrets" => %([{"id": "mysecret", "type": "value"}]),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("type is value but all of the following are missing: value found in secrets")
  end

  it "fails secret src+value as mutually exclusive, no_log-blanking the secret value" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "secrets" => %([{"id": "mysecret", "type": "file", "src": "/tmp/f", "value": "v"}]),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusi********e: src|en********|********alue found in secrets")
  end

  it "fails an invalid output type choice" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "outputs" => %([{"type": "banana"}]),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of type must be one of: local, tar, oci, docker, image, got: banana found in outputs")
  end

  it "fails output type=local without dest via required_if" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "outputs" => %([{"type": "local"}]),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("type is local but all of the following are missing: dest found in outputs")
  end

  it "fails output dest+name as mutually exclusive" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "outputs" => %([{"type": "local", "dest": "/tmp/d", "name": ["n"]}]),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: dest|name found in outputs")
  end

  it "fails a plain-string secrets value in the no_log pass with bare check_type_dict wording" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"    => "krikri/test",
      "path"    => "/tmp/krikri-no-such-dir",
      "secrets" => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("dictionary requested, could not parse JSON or key=value")
  end

  it "rejects a top-level parameter outside the argument_spec (deferred to last)" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name"   => "krikri/test",
      "path"   => "/tmp/krikri-no-such-dir",
      "banana" => "x",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.docker.docker_image_build) module: banana. " \
                                 "Supported parameters include: args, cache_from, dockerfile, etc_hosts, labels, " \
                                 "name, network, nocache, outputs, path, platform, pull, rebuild, secrets, " \
                                 "shm_size, tag, target.")
  end

  it "fails a nonexistent path directory only after validation passed" do
    result = PluginSpecHelper.run("docker_image_build", {
      "name" => "krikri/test",
      "path" => "/tmp/krikri-no-such-dir",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("\"/tmp/krikri-no-such-dir\" is not an existing directory")
  end
end
