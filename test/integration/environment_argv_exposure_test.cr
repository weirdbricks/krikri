require "../minitest_helper"

# Security regression: BasePlugin#remote_exec used to apply the task's
# `environment:` by prefixing the command string with `export K='V'; ...`.
# That prefix lived INSIDE the `/bin/bash -c <string>` argv element, so any
# local user on the machine could read the (often secret) values with `ps`
# while the task ran - Ansible instead hands the environment dict to
# the module process's own environment, where it never appears in an argv.
#
# Driven through the real shell plugin binary via PluginSpecHelper: shell
# always forces the shell path through #remote_exec, so it exercises the
# full env plumbing (task_environment -> LocalExecutor env:).
describe "environment: values stay out of the spawned process argv" do
  # Deliberately hostile value: quotes, dollars, backticks, a leading dash
  # (would parse as a flag if re-parsed), spaces, and an embedded newline -
  # every shape that used to have to survive shell single-quoting in the
  # export prefix and must now survive the process-environment path
  # byte-exact instead.
  def secret : String
    "s3cr3t'x\"y$z`w -dash val\nline2"
  end

  it "the child sees the byte-exact value" do
    value_file = PluginSpecHelper.tmp_path("env-argv-value")
    result = PluginSpecHelper.run("shell", {
      "cmd"          => "printf '%s' \"$KRIKRI_SPEC_SECRET\" > #{value_file}",
      "_environment" => %({"KRIKRI_SPEC_SECRET": #{secret.to_json}}),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(value_file).must_equal(secret)
  ensure
    File.delete(value_file) if value_file && File.exists?(value_file)
  end

  it "the value does not appear in the spawned shell's argv" do
    # /proc/$$/cmdline is the shell process remote_exec spawned - under the
    # old design its argv carried the whole `export K='V'; <cmd>` string.
    result = PluginSpecHelper.run("shell", {
      "cmd"          => "tr '\\0' ' ' < /proc/$$/cmdline",
      "_environment" => %({"KRIKRI_SPEC_SECRET": #{secret.to_json}}),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["stdout"].as_s.includes?(secret).must_equal(false)
    result["stdout"].as_s.includes?("s3cr3t").must_equal(false)
  end

  it "shell: still interpolates the exported value like Ansible" do
    result = PluginSpecHelper.run("shell", {
      "cmd"          => "echo \"$KRIKRI_SPEC_SECRET\"",
      "_environment" => %({"KRIKRI_SPEC_SECRET": #{secret.to_json}}),
    })

    # shell's stdout is rstripped of the trailing newline; the embedded
    # one survives.
    result["stdout"].as_s.must_equal(secret.chomp)
  end
end
