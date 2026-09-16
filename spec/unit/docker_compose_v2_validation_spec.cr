require "../spec_helper"

# Pins plugins/docker_compose_v2.cr's argument-validation surface against
# real community.docker.docker_compose_v2's AnsibleModule setup
# (source-verified against the collection's _compose_v2.py module_utils +
# ansible-core's arg_spec.ArgumentSpecValidator.validate order):
#
# - required_one_of (definition, project_src) when neither is given
# - choices render in argument_spec declaration order (state is
#   "absent, present, stopped, restarted")
# - remove_images is choices-validated [all, local]
# - required_by: definition requires project_name ("missing parameter(s)
#   required by 'definition': project_name")
# - mutually_exclusive: (definition, project_src) and (definition, files)
#   ("parameters are mutually exclusive: definition|project_src")
# - timeout/wait_timeout are type-converted int, definition/scale are
#   dict, with parameters.py's exact wording
describe "docker_compose_v2 plugin argument validation" do
  it "fails without definition or project_src (required_one_of)" do
    result = PluginSpecHelper.run("docker_compose_v2", {"state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("one of the following is required: definition, project_src")
  end

  it "fails an invalid state choice in declaration order" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/tmp/x",
      "state"       => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: absent, present, stopped, restarted, got: banana")
  end

  it "fails an invalid pull choice" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/tmp/x",
      "pull"        => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of pull must be one of: always, missing, never, policy, got: banana")
  end

  it "fails an invalid remove_images choice" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"   => "/tmp/x",
      "state"         => "absent",
      "remove_images" => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of remove_images must be one of: all, local, got: banana")
  end

  it "fails definition without project_name (required_by)" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "definition" => %({"services": {"foo": {"image": "alpine"}}}),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing parameter(s) required by 'definition': project_name")
  end

  it "fails definition + project_src (mutually exclusive)" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src"  => "/tmp/x",
      "project_name" => "krikri",
      "definition"   => %({"services": {"foo": {"image": "alpine"}}}),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: definition|project_src")
  end

  it "fails definition + files (mutually exclusive)" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_name" => "krikri",
      "files"        => "compose.yaml",
      "definition"   => %({"services": {"foo": {"image": "alpine"}}}),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: definition|files")
  end

  it "fails a non-integer timeout with the type-conversion wording" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/tmp/x",
      "timeout"     => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'timeout' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int"
    )
  end

  it "accepts a string-integer timeout" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/nonexistent-krikri-dir",
      "timeout"     => "30",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should_not contain("unable to convert")
  end

  it "fails a non-dict scale with the type-conversion wording" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/tmp/x",
      "scale"       => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'scale' is of type <class 'str'> and we were unable to convert to dict: " \
      "dictionary requested, could not parse JSON or key=value"
    )
  end

  it "fails a JSON-list scale with the list wording" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_src" => "/tmp/x",
      "scale"       => %(["banana"]),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'scale' is of type <class 'list'> and we were unable to convert to dict: " \
      "<class 'list'> cannot be converted to a dict"
    )
  end

  it "fails a non-dict definition with the type-conversion wording" do
    result = PluginSpecHelper.run("docker_compose_v2", {
      "project_name" => "krikri",
      "definition"   => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'definition' is of type <class 'str'> and we were unable to convert to dict: " \
      "dictionary requested, could not parse JSON or key=value"
    )
  end
end
