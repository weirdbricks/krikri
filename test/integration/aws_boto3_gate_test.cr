require "../minitest_helper"
require "file_utils"

# The amazon.aws modules' boto3 gate must name the interpreter Ansible's
# discovery hands the module - python_lib_gate's INTERPRETER_FALLBACK
# walk - not a bare `python3`. A bare probe reports the /usr/bin/python3
# SYMLINK's sys.executable where real reports the versioned interpreter
# it discovered (/usr/bin/python3.10 on the ubuntu target), which is
# exactly the byte difference in issue #397's ec2_instance failure
# message. python_lib_gate's own gates were fixed for this in the kpg33
# sweep; the AWS gate kept its own older bare-python3 probe.
#
# The failure branch is forced deterministically the same way
# docker_sdk_gate_test does it: a stub `botocore` package on PYTHONPATH
# whose __init__ raises ImportError, which precedes site-packages in
# sys.path, so the probe `import botocore, boto3` fails on every host -
# under whichever interpreter the gate spawns.
require "../../src/krikri/plugin_helpers/python_lib_gate"

describe "aws boto3 gate at plugin level" do
  serial!

  it "fails ec2_instance with the import wording naming the discovered interpreter" do
    stub_root = PluginSpecHelper.tmp_path("boto3-gate-stub")
    FileUtils.rm_rf(stub_root)
    FileUtils.mkdir_p(File.join(stub_root, "botocore"))
    File.write(File.join(stub_root, "botocore", "__init__.py"),
      "raise ImportError(\"No module named 'botocore'\")\n")

    python = Krikri.target_python_executable
    skip "no python on this host (the gate needs an interpreter to fail)" unless python
    expected = Krikri.missing_required_lib_message("botocore and boto3", python)

    result = PluginSpecHelper.run("ec2_instance", {
      "name"          => "krikri-ec2-gate",
      "image_id"      => "ami-krikri000000000000000000000000000",
      "instance_type" => "t2.micro",
      "state"         => "present",
      "region"        => "us-east-1",
    }, env: {"PYTHONPATH" => stub_root})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(expected)
  ensure
    FileUtils.rm_rf(stub_root) if stub_root && Dir.exists?(stub_root)
  end
end
