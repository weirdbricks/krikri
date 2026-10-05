require "../minitest_helper"

# Regression: `with_environment` (src/krikri/base_plugin.cr) interpolated the
# task `environment:` KEY unquoted into the `export #{key}='#{value}'` prefix
# that `#remote_exec` prepends to every plugin command string. That string is
# executed by a real shell (LocalExecutor falls through to /bin/bash -c; the
# SSH side runs `ssh host <string>`), so a task-controlled key like
# `X; touch /tmp/pwned; #` was arbitrary command execution on the managed
# host. The VALUE side was always Shell.single_quote'd - only the key was
# raw. Ansible hands the environment dict to subprocess's `env:` and can
# never execute through a key, so keys that are valid POSIX identifiers
# behave identically and anything else is now rejected with a clear plugin
# error instead of reaching the shell.
#
# Driven through the real getent plugin binary via PluginSpecHelper - getent
# is one of the plugins that shells out via #remote_exec, which is the path
# with_environment guards.
# The classic suite kept the marker path in a describe-body local (its
# its are closures over it); minitest's describe bodies are class
# bodies, so it becomes a method. The marker is deleted-then-probed, so
# it stays at this fixed /tmp path on purpose: the injected environment
# KEY is what must not execute, and its text is baked into the spec.
private def marker : String
  "/tmp/krikri-env-key-injection-marker"
end

describe "environment: key validation (command injection regression)" do
  it "rejects a key with shell metacharacters without executing it" do
    File.delete(marker) if File.exists?(marker)

    result = PluginSpecHelper.run("getent", {
      "database"     => "passwd",
      "key"          => "root",
      "_environment" => %({"X; touch #{marker}; #": "x"}),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Invalid environment variable name")
    File.exists?(marker).must_equal(false)
  end

  it "rejects an apostrophe-escape payload key without executing it" do
    File.delete(marker) if File.exists?(marker)

    result = PluginSpecHelper.run("getent", {
      "database"     => "passwd",
      "key"          => "root",
      "_environment" => %({"K'; touch #{marker}; K'": "x"}),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Invalid environment variable name")
    File.exists?(marker).must_equal(false)
  end

  it "still honors a valid identifier key (normal environment: usage)" do
    result = PluginSpecHelper.run("getent", {
      "database"     => "passwd",
      "key"          => "root",
      "_environment" => %({"KRIKRI_SPEC_VALID_KEY": "task-env-value", "PATH": "/usr/bin:/bin"}),
    })

    result["failed"]?.try(&.as_bool).wont_equal(true)
    result["ansible_facts"]["getent_passwd"].as_h.has_key?("root").must_equal(true)
  end
end
