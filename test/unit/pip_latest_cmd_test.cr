require "../minitest_helper"

# Regression spec for issue #1215 (agarthetiger.ansible_mini_pitft):
# real ansible-core's pip.py resolves the pip executable through
# get_bin_path, so a role's `executable: pip3` reaches the target as
# the PATH-resolved absolute path (/usr/bin/pip3) and is reported that
# way in the failing result's `cmd`. Its state_map also spells
# state=latest as ['install', '-U'], while krikri reported the bare
# name and the long `--upgrade` alias - a byte difference in the task's
# output.
describe "pip: state=latest argv and executable resolution" do
  it "reports the PATH-resolved executable and -U for state=latest" do
    with_path_installed_failing_pip do |_, script, env|
      result = PluginSpecHelper.run("pip", {
        "name"       => "setuptools",
        "state"      => "latest",
        "executable" => "pip3",
      }, env: env)

      result["failed"].as_bool.must_equal(true)
      result["cmd"].as_a.map(&.as_s).must_equal([script, "install", "-U", "setuptools"])
    end
  end

  it "carries -U ahead of --force-reinstall for state=forcereinstall" do
    with_failing_pip do |script|
      result = PluginSpecHelper.run("pip", {
        "name"       => "setuptools",
        "state"      => "forcereinstall",
        "executable" => script,
      })

      result["failed"].as_bool.must_equal(true)
      result["cmd"].as_a.map(&.as_s).must_equal([script, "install", "-U", "--force-reinstall", "setuptools"])
    end
  end

  it "still runs a plain install with no upgrade flag for state=present" do
    with_failing_pip do |script|
      result = PluginSpecHelper.run("pip", {
        "name"       => "setuptools",
        "state"      => "present",
        "executable" => script,
      })

      result["failed"].as_bool.must_equal(true)
      result["cmd"].as_a.map(&.as_s).must_equal([script, "install", "setuptools"])
    end
  end
end

# Installs a failing fake pip as `pip3` in its own dir on the CHILD's
# PATH, which is what lets the bare `executable: pip3` lookup resolve
# to the absolute path Ansible's get_bin_path returns.
private def with_path_installed_failing_pip(&)
  dir = PluginSpecHelper.tmp_path("pip-resolve")
  Dir.mkdir(dir)
  script = File.join(dir, "pip3")
  write_failing_pip(script)
  env = {"PATH" => "#{dir}:#{ENV["PATH"]? || "/usr/bin:/bin"}"}
  begin
    yield dir, script, env
  ensure
    File.delete(script)
    Dir.delete(dir)
  end
end

private def with_failing_pip(&)
  dir = PluginSpecHelper.tmp_path("pip-plain")
  Dir.mkdir(dir)
  script = File.join(dir, "fakepip")
  write_failing_pip(script)
  begin
    yield script
  ensure
    File.delete(script)
    Dir.delete(dir)
  end
end

private def write_failing_pip(script : String) : Nil
  File.write(script, %(#!/bin/sh\necho "error: externally-managed-environment" >&2\nexit 1\n))
  File.chmod(script, 0o755)
end
