require "../spec_helper"

# Regression: `with_environment` (src/krikri/base_plugin.cr) interpolated the
# task `environment:` KEY unquoted into the `export #{key}='#{value}'` prefix
# that `#remote_exec` prepends to every plugin command string. That string is
# executed by a real shell (LocalExecutor falls through to /bin/bash -c; the
# SSH side runs `ssh host <string>`), so a task-controlled key like
# `X; touch /tmp/pwned; #` was arbitrary command execution on the managed
# host. The VALUE side was always Shell.single_quote'd - only the key was
# raw. Real Ansible hands the environment dict to subprocess's `env:` and can
# never execute through a key, so keys that are valid POSIX identifiers
# behave identically and anything else is now rejected with a clear plugin
# error instead of reaching the shell.
#
# Driven through the real getent plugin binary via PluginSpecHelper - getent
# is one of the plugins that shells out via #remote_exec, which is the path
# with_environment guards.
describe "environment: key validation (command injection regression)" do
  marker = "/tmp/krikri-env-key-injection-marker"

  it "rejects a key with shell metacharacters without executing it" do
    File.delete(marker) if File.exists?(marker)

    result = PluginSpecHelper.run("getent", {
      "database"     => "passwd",
      "key"          => "root",
      "_environment" => %({"X; touch #{marker}; #": "x"}),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Invalid environment variable name")
    File.exists?(marker).should be_false
  end

  it "rejects an apostrophe-escape payload key without executing it" do
    File.delete(marker) if File.exists?(marker)

    result = PluginSpecHelper.run("getent", {
      "database"     => "passwd",
      "key"          => "root",
      "_environment" => %({"K'; touch #{marker}; K'": "x"}),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Invalid environment variable name")
    File.exists?(marker).should be_false
  end

  it "still honors a valid identifier key (normal environment: usage)" do
    result = PluginSpecHelper.run("getent", {
      "database"     => "passwd",
      "key"          => "root",
      "_environment" => %({"KRIKRI_SPEC_VALID_KEY": "task-env-value", "PATH": "/usr/bin:/bin"}),
    })

    result["failed"]?.try(&.as_bool).should_not(be_true)
    result["ansible_facts"]["getent_passwd"].as_h.has_key?("root").should be_true
  end
end
