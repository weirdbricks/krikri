require "../spec_helper"
require "../../src/krikri/plugin_helpers/modprobe_command"
require "../../src/krikri/plugin_helpers/easy_install"

# Regression specs for the shell-injection sweep (finding H1 of
# SECURITY_REVIEW_DEEPSEEK.md): a task param containing shell
# metacharacters (`;`, `|`, apostrophes) that reaches a plugin's
# `/bin/bash -c` command string must stay a single literal argument of
# the intended command - it must never split into extra shell
# operations. The observable: a `touch /tmp/...` payload inside the
# param value leaves no file behind (before the fix it did), and the
# plugin treats the value as one literal argument (fails or no-ops the
# way it would for any unknown name/path).
describe "plugin task params cannot inject shell operations" do
  it "systemd treats an injected name as one literal unit name, not extra commands" do
    pwned = "/tmp/krikri-pwn-systemd-#{Random::Secure.hex(8)}"
    result = PluginSpecHelper.run("systemd", {
      "name"  => "x; touch #{pwned}; #",
      "state" => "stopped",
    })

    File.exists?(pwned).should be_false
  end

  it "timezone verifies an injected name as one literal zone, not extra commands" do
    pwned = "/tmp/krikri-pwn-timezone-#{Random::Secure.hex(8)}"
    result = PluginSpecHelper.run("timezone", {
      "name" => "UTC'; touch #{pwned}; '",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("is not available")
    File.exists?(pwned).should be_false
  end

  it "debconf set_selections cannot break out through an apostrophe in value/pkg" do
    pwned = "/tmp/krikri-pwn-debconf-#{Random::Secure.hex(8)}"
    result = PluginSpecHelper.run("debconf", {
      "name"     => "krikri-spec-package",
      "question" => "krikri-spec/question",
      "vtype"    => "string",
      "value"    => "' | touch #{pwned}; #",
    })

    File.exists?(pwned).should be_false
  end

  it "stat stats an injected path as one literal path, not extra commands" do
    pwned = "/tmp/krikri-pwn-stat-#{Random::Secure.hex(8)}"
    result = PluginSpecHelper.run("stat", {
      "path" => "/tmp; touch #{pwned}; #",
    })

    File.exists?(pwned).should be_false
  end
end

# Pure command-builder quoting regression: injected values must end up
# as single-quoted shell words, safe values verbatim (exact behavior
# preserved for well-formed inputs).
describe "shell-quoted command builders" do
  it "quotes the modprobe module name and params tokens" do
    Krikri::PluginHelpers::ModprobeCommand.load_command("/usr/sbin/modprobe", "x; touch /tmp/pwned", nil)
      .should eq("/usr/sbin/modprobe 'x; touch /tmp/pwned'")
    Krikri::PluginHelpers::ModprobeCommand.load_command("/usr/sbin/modprobe", "dummy", "numdummies=2 foo=bar")
      .should eq("/usr/sbin/modprobe dummy numdummies=2 foo=bar")
  end

  it "quotes the easy_install package name and virtualenv paths" do
    Krikri::PluginHelpers::EasyInstall.probe_command("easy_install", [] of String, "pkg; touch /tmp/pwned")
      .should eq("easy_install --dry-run 'pkg; touch /tmp/pwned'")
    Krikri::PluginHelpers::EasyInstall.install_command("easy_install", [] of String, "pkg; touch /tmp/pwned")
      .should eq("easy_install 'pkg; touch /tmp/pwned'")
    Krikri::PluginHelpers::EasyInstall.venv_create_command("virtualenv", "/venv; touch /tmp/pwned", false)
      .should eq("virtualenv '/venv; touch /tmp/pwned'")
  end
end
