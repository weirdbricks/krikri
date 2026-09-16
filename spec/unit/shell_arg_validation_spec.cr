require "../spec_helper"

# Pins plugins/shell.cr's AnsibleModule argument-validation surface
# against real ansible.builtin.shell (bookworm ansible-core 2.14, where
# the shell module IS command.py with _uses_shell=True; live-diffed via
# the podman-diff shell_edge_cases harness). Previously only warn: was
# hand-rolled with 2.19-era wording that real 2.14 never emits - real
# names the module "ansible.legacy.command" and lists the 10-param
# argspec with no cmd: and no expand_argument_vars: (SH14/SH17), the
# missing-command failure is "no command given" not
# "Missing required parameter: cmd" (SH15), and bool-typed params fail
# at setup with parameters.py wording (SH18).
describe "shell plugin argument validation" do
  it "rejects expand_argument_vars under the 2.14 command.py argspec wording (SH14)" do
    result = PluginSpecHelper.run("shell", {"_raw_params" => "echo hi", "expand_argument_vars" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (ansible.legacy.command) module: expand_argument_vars. " \
                                 "Supported parameters include: _raw_params, _uses_shell, argv, chdir, creates, " \
                                 "executable, removes, stdin, stdin_add_newline, strip_empty_ends.")
  end

  it "rejects warn like any other out-of-spec param (SH17)" do
    result = PluginSpecHelper.run("shell", {"_raw_params" => "echo hi", "warn" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (ansible.legacy.command) module: warn. " \
                                 "Supported parameters include: _raw_params, _uses_shell, argv, chdir, creates, " \
                                 "executable, removes, stdin, stdin_add_newline, strip_empty_ends.")
  end

  it "fails a missing command with real's 'no command given' wording (SH15)" do
    result = PluginSpecHelper.run("shell", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("no command given")
  end

  it "fails a non-boolean stdin_add_newline at setup before anything runs (SH18)" do
    result = PluginSpecHelper.run("shell", {"_raw_params" => "echo hi", "stdin_add_newline" => "sometimes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'stdin_add_newline' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'sometimes' is not a valid boolean.  Valid booleans include: ")
  end

  it "still executes when every param is inside the argspec" do
    result = PluginSpecHelper.run("shell", {"_raw_params" => "echo sh-validation-ok"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["stdout"].as_s.should eq("sh-validation-ok")
  end
end
