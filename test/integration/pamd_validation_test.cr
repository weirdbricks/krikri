require "../minitest_helper"
require "file_utils"

# Regression spec for community.general.pamd's argument-validation
# surface (AnsibleModule setup, all running BEFORE the service file is
# opened) and the post-action service.validate() pass over every line.
# Found via the pamd_edge_cases podman-diff case (live-diffed against
# ansible-playbook, community.general 13.3.0). All file access is
# under a tmp_path subtree via the `path` param - never the real
# /etc/pam.d.

private def base_dir : String
  PluginSpecHelper.tmp_path("pam.d")
end

private def tmp_dir(name : String) : String
  dir = PluginSpecHelper.tmp_path(name)
  `rm -rf #{dir}`
  Dir.mkdir_p(dir)
  dir
end

describe "pamd plugin - argument validation" do
  it "reports all missing required arguments, sorted" do
    result = PluginSpecHelper.run("pamd", {} of String => String)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: control, module_path, name, type")
  end

  it "rejects an invalid type choice in the spec's declaration order" do
    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-spec",
      "type"        => "bogus",
      "control"     => "required",
      "module_path" => "pam_first.so",
      "path"        => base_dir,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "value of type must be one of: account, -account, auth, -auth, password, -password, session, -session, got: bogus"
    )
  end

  it "rejects an invalid state choice in the spec's sorted order" do
    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-spec",
      "type"        => "auth",
      "control"     => "required",
      "module_path" => "pam_first.so",
      "state"       => "bogus",
      "path"        => base_dir,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "value of state must be one of: absent, after, args_absent, args_present, before, updated, got: bogus"
    )
  end

  it "requires the new_* triple for state before" do
    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-spec",
      "type"        => "auth",
      "control"     => "required",
      "module_path" => "pam_first.so",
      "state"       => "before",
      "path"        => base_dir,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "state is before but all of the following are missing: new_control, new_type, new_module_path"
    )
  end

  it "requires module_arguments for state args_present" do
    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-spec",
      "type"        => "auth",
      "control"     => "required",
      "module_path" => "pam_first.so",
      "state"       => "args_present",
      "path"        => base_dir,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "state is args_present but all of the following are missing: module_arguments"
    )
  end

  it "rejects an unconvertible backup bool with the convert_bool wording" do
    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-spec",
      "type"        => "auth",
      "control"     => "required",
      "module_path" => "pam_first.so",
      "backup"      => "bogus",
      "path"        => base_dir,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("argument 'backup' is of type <class 'str'> and we were unable to convert to bool")
    result["msg"].as_s.must_include("The value 'bogus' is not a valid boolean. Valid booleans include:")
  end

  it "rejects unsupported params with the Unsupported parameters wording" do
    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-spec",
      "type"        => "auth",
      "control"     => "required",
      "module_path" => "pam_first.so",
      "bogus_param" => "1",
      "path"        => base_dir,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (community.general.pamd) module: bogus_param. " \
      "Supported parameters include: backup, control, module_arguments, module_path, name, " \
      "new_control, new_module_path, new_type, path, state, type."
    )
  end

  it "reports a missing service file with the real open-failure wording" do
    dir = tmp_dir("pamd-missing-file")
    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-no-such-service",
      "type"        => "auth",
      "control"     => "required",
      "module_path" => "pam_first.so",
      "path"        => dir,
    })
    result["failed"].as_bool.must_equal(true)
    path = File.join(dir, "krikri-no-such-service")
    result["msg"].as_s.must_equal(
      "Unable to open/read PAM module file #{path} with error [Errno 2] No such file or directory: '#{path}'."
    )
  end
end

describe "pamd plugin - service validation" do
  it "fails on an unparseable line and writes nothing" do
    dir = tmp_dir("pamd-garbage")
    File.write(File.join(dir, "krikri-garbage"), "auth required pam_ok.so\nthis is garbage\n")

    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-garbage",
      "type"        => "auth",
      "control"     => "required",
      "module_path" => "pam_ok.so",
      "new_control" => "sufficient",
      "path"        => dir,
    })
    result["failed"].as_bool.must_equal(true)
    File.read(File.join(dir, "krikri-garbage")).must_equal("auth required pam_ok.so\nthis is garbage\n")
  end

  it "fails an invalid new_control and writes nothing" do
    dir = tmp_dir("pamd-bad-control")
    File.write(File.join(dir, "krikri-ctrl"), "account sufficient pam_second.so arg1 arg2\n")

    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-ctrl",
      "type"        => "account",
      "control"     => "sufficient",
      "module_path" => "pam_second.so",
      "new_control" => "bogus",
      "path"        => dir,
    })
    result["failed"].as_bool.must_equal(true)
    File.read(File.join(dir, "krikri-ctrl")).must_equal("account sufficient pam_second.so arg1 arg2\n")
  end

  it "fails an invalid bracketed-control action and writes nothing" do
    dir = tmp_dir("pamd-bad-bracket")
    File.write(File.join(dir, "krikri-bracket"), "account sufficient pam_second.so arg1 arg2\n")

    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-bracket",
      "type"        => "account",
      "control"     => "sufficient",
      "module_path" => "pam_second.so",
      "new_control" => "[success=1 default=bogusaction]",
      "path"        => dir,
    })
    result["failed"].as_bool.must_equal(true)
    File.read(File.join(dir, "krikri-bracket")).must_equal("account sufficient pam_second.so arg1 arg2\n")
  end

  it "rejects bracketed complex arguments with args_present" do
    dir = tmp_dir("pamd-bracketed-args")
    File.write(File.join(dir, "krikri-bargs"), "auth required pam_first.so\n")

    result = PluginSpecHelper.run("pamd", {
      "name"             => "krikri-bargs",
      "type"             => "auth",
      "control"          => "required",
      "module_path"      => "pam_first.so",
      "module_arguments" => "[success=1]",
      "state"            => "args_present",
      "path"             => dir,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unable to process bracketed '[' complex arguments with 'args_present'. Please use 'updated'."
    )
  end

  it "applies a valid bracketed-control update and is idempotent" do
    dir = tmp_dir("pamd-valid-update")
    file = File.join(dir, "krikri-valid")
    File.write(file, "account sufficient pam_second.so arg1 arg2\n")

    result = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-valid",
      "type"        => "account",
      "control"     => "sufficient",
      "module_path" => "pam_second.so",
      "new_control" => "[success=2 default=ignore]",
      "path"        => dir,
    })
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    File.read(file).must_include("account    [success=2 default=ignore] pam_second.so arg1 arg2")

    rerun = PluginSpecHelper.run("pamd", {
      "name"        => "krikri-valid",
      "type"        => "account",
      "control"     => "[success=2 default=ignore]",
      "module_path" => "pam_second.so",
      "new_control" => "[success=2 default=ignore]",
      "path"        => dir,
    })
    falsey?(rerun["failed"]?.try(&.as_bool)).must_equal(true)
    rerun["changed"].as_bool.must_equal(false)
  end
end
