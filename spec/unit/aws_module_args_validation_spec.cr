require "../spec_helper"
require "../../src/krikri/plugin_helpers/aws_module_args"
require "../../src/krikri/plugin_helpers/aws_module_specs"

# Regression for the podman-diff ec2_*/iam_user_info edge-case round:
# real amazon.aws modules wrap AnsibleModule in AnsibleAWSModule, so the
# argument-spec surface (unsupported params, mutually_exclusive,
# required_one_of/required_if/required_by, choices, type coercion, and
# the _list_no_log_values dict-conversion ordering) fires before any AWS
# API work. All wordings below were live-verified against amazon.aws
# 11.4.0 under ansible-core 2.14 via the podman-diff probe container.

def aws_validate(spec, params)
  Krikri::PluginHelpers::AwsModuleArgs.validate(spec, params).try(&.msg)
end

def aws_fail_msg(spec, params) : String
  aws_validate(spec, params) || raise "expected validation failure, got success"
end

describe "AwsModuleArgs: unsupported parameters" do
  it "rejects an out-of-spec top-level parameter with the sorted key/alias list" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_KEY,
      {"name" => "deploy", "krikri_not_an_ec2_key_param" => "true"})
    msg.should_not be_nil
    msg.should contain("Unsupported parameters for (amazon.aws.ec2_key) module: krikri_not_an_ec2_key_param")
    msg.should contain("Supported parameters include:")
  end

  it "rejects an out-of-spec suboption key with the param.key form" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_INSTANCE,
      {"image" => %({"id": "ami-123456", "krikri_bogus": 1})})
    msg.should_not be_nil
    msg.should contain("Unsupported parameters for (amazon.aws.ec2_instance) module: image.krikri_bogus")
    msg.should contain("Supported parameters include: id, kernel, ramdisk")
  end
end

describe "AwsModuleArgs: mutually_exclusive" do
  it "fails when two mutually exclusive params are both set" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_KEY,
      {"name" => "deploy", "key_material" => "ssh-rsa AAA", "key_type" => "ed25519"})
    msg.should_not be_nil
    msg.should contain("parameters are mutually exclusive: key_material|key_type")
  end

  it "fires before missing-required (mutually_exclusive precedes required in the order)" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_KEY,
      {"key_material" => "ssh-rsa AAA", "key_type" => "ed25519"})
    msg.should_not be_nil
    msg.should contain("parameters are mutually exclusive")
  end
end

describe "AwsModuleArgs: required params" do
  it "reports a missing required argument" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_KEY, {"force" => "true"})
    msg.should_not be_nil
    msg.should contain("missing required arguments: name")
  end

  it "reports required_one_of" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_SECURITY_GROUP,
      {"description" => "web"})
    msg.should_not be_nil
    msg.should contain("one of the following is required: name, group_id")
  end

  it "reports required_if" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_SECURITY_GROUP,
      {"state" => "present", "name" => "web"})
    msg.should_not be_nil
    msg.should contain("state is present but all of the following are missing: description")
  end

  it "reports required_by inside a sub-spec" do
    rules = %([{"cidr_ip": "10.0.0.0/8", "icmp_code": 1}])
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_SECURITY_GROUP,
      {"name" => "web", "description" => "web", "rules" => rules})
    msg.should_not be_nil
    msg.should contain("missing parameter(s) required by 'icmp_code': icmp_type found in rules")
  end
end

describe "AwsModuleArgs: choices" do
  it "rejects a value outside the allowed choices" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_KEY,
      {"name" => "deploy", "state" => "running"})
    msg.should_not be_nil
    msg.should contain("value of state must be one of: present, absent, got: running")
  end

  it "rejects an out-of-choices suboption value with the found-in suffix" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_INSTANCE,
      {"cpu_options" => %({"core_count": 2, "threads_per_core": 7})})
    msg.should_not be_nil
    msg.should contain("value of threads_per_core must be one of: 1, 2, got: 7 found in cpu_options")
  end
end

describe "AwsModuleArgs: type coercion" do
  it "rejects a non-boolean value for a bool-typed param" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_INSTANCE,
      {"wait" => "sometimes"})
    msg.should_not be_nil
    msg.should contain("argument 'wait' is of type <class 'str'> and we were unable to convert to bool")
    msg.should contain("The value 'sometimes' is not a valid boolean")
  end

  it "accepts boolean-convertible strings for a bool-typed param" do
    msg = aws_validate(Krikri::PluginHelpers::AwsModuleSpecs::EC2_INSTANCE,
      {"wait" => "yes", "purge_tags" => "0"})
    msg.should be_nil
  end

  it "rejects a non-integer value for an int-typed param" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_INSTANCE,
      {"wait_timeout" => "soon"})
    msg.should_not be_nil
    msg.should contain("argument 'wait_timeout' is of type <class 'str'> and we were unable to convert to int")
  end

  it "accepts numeric strings for an int-typed param" do
    msg = aws_validate(Krikri::PluginHelpers::AwsModuleSpecs::EC2_INSTANCE,
      {"wait_timeout" => "300"})
    msg.should be_nil
  end
end

describe "AwsModuleArgs: IN8 dict-with-sub-spec _list_no_log_values ordering" do
  it "gives the bare dict-parse error (no argument-prefix) for a dict param WITH an options= sub-spec" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_INSTANCE,
      {"image" => "ami-123456"})
    msg.should_not be_nil
    msg.should eq("dictionary requested, could not parse JSON or key=value")
  end

  it "keeps the 'argument X is of type' prefix for a plain dict param WITHOUT an options= sub-spec" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_KEY,
      {"name" => "deploy", "tags" => "not-a-dict"})
    msg.should_not be_nil
    msg.should contain("argument 'tags' is of type <class 'str'> and we were unable to convert to dict: " \
                       "dictionary requested, could not parse JSON or key=value")
  end

  it "passes a k=v string through check_type_dict for a dict param with an options= sub-spec" do
    msg = aws_validate(Krikri::PluginHelpers::AwsModuleSpecs::EC2_INSTANCE,
      {"image" => "id=ami-123456"})
    msg.should be_nil
  end

  it "reports the Mapping-check wording (with real's 'must by a' typo) for a non-string non-dict list element" do
    msg = aws_fail_msg(Krikri::PluginHelpers::AwsModuleSpecs::EC2_INSTANCE,
      {"image" => "[1]"})
    msg.should_not be_nil
    msg.should contain("Value '1' in the sub parameter field 'image' must by a dict, not 'int'")
  end
end
