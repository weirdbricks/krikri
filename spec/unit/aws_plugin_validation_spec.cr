require "../spec_helper"
require "json"

# Plugin-boundary regression for the podman-diff ec2_*/iam_user_info
# round: each amazon.aws plugin wires AwsModuleArgs.validate + the
# boto3_gate ahead of its native Query-API helpers, so an invalid
# invocation fails at the plugin with real Ansible's wording before any
# AWS work (and before a boto3-less host ever matters).

private def run_aws_plugin(plugin : String, params : Hash(String, String)) : JSON::Any
  config = {
    "params" => params,
    "vars"   => Hash(String, JSON::Any).new,
    "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
  }.to_json
  stdout = IO::Memory.new
  Process.run("bin/plugins/#{plugin}", input: IO::Memory.new(config), output: stdout, error: stdout)
  JSON.parse(stdout.to_s)
end

describe "ec2_instance plugin: argument-spec validation" do
  it "fails with the bare dict-parse error for a scalar image (dict with options= sub-spec)" do
    result = run_aws_plugin("ec2_instance", {
      "image"        => "ami-123456",
      "instance_type" => "t3.micro",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("dictionary requested, could not parse JSON or key=value")
  end

  it "fails with the prefixed dict error for a plain dict param without a sub-spec" do
    result = run_aws_plugin("ec2_instance", {
      "image_id"  => "ami-123456",
      "instance_type" => "t3.micro",
      "tags"      => "not-a-dict",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'tags' is of type <class 'str'> and we were unable to convert to dict")
  end
end

describe "ec2_key plugin: argument-spec validation" do
  it "rejects an out-of-spec parameter at the plugin boundary" do
    result = run_aws_plugin("ec2_key", {
      "name"     => "deploy",
      "krikri_not_an_ec2_key_param" => "true",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Unsupported parameters for (amazon.aws.ec2_key) module: krikri_not_an_ec2_key_param")
  end

  it "rejects an out-of-choices state value" do
    result = run_aws_plugin("ec2_key", {
      "name"  => "deploy",
      "state" => "running",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of state must be one of: present, absent, got: running")
  end
end

describe "ec2_security_group plugin: argument-spec validation" do
  it "reports required_one_of at the plugin boundary" do
    result = run_aws_plugin("ec2_security_group", {"description" => "web"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("one of the following is required: name, group_id")
  end
end
