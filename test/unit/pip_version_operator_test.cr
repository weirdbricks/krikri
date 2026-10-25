require "../minitest_helper"

# Regression spec for operator-prefixed version pins (issue #357):
# `version: ">=22"` used to build the requirement `pip==>=22`, which pip
# rejects outright ("Invalid requirement: 'pip==>=22'") where
# ansible-playbook installs `pip>=22`. Ansible's pip.py
# (Package.__init__) strips leading whitespace and joins name and
# version with `==` only when the stripped version starts with a digit -
# a leading comparison operator becomes the separator itself.
#
# Driven through the real plugin binary via PluginSpecHelper with a fake
# pip executable that records its install arguments, so the spec asserts
# the requirement pip actually received.
describe "pip: operator-prefixed version pins" do
  it "builds pip>=22 for version >=22 (no separator before the operator)" do
    with_recording_fake_pip do |script, recorded|
      result = PluginSpecHelper.run("pip", {
        "name"       => "pip",
        "version"    => ">=22",
        "executable" => script,
      })

      (result["failed"]?.try(&.as_bool) || false).must_equal(false)
      File.read(recorded).chomp.must_equal("pip>=22")
    end
  end

  it "builds pip~=1.2 for version ~=1.2" do
    with_recording_fake_pip do |script, recorded|
      result = PluginSpecHelper.run("pip", {
        "name"       => "pip",
        "version"    => "~=1.2",
        "executable" => script,
      })

      (result["failed"]?.try(&.as_bool) || false).must_equal(false)
      File.read(recorded).chomp.must_equal("pip~=1.2")
    end
  end

  it "builds pip==22 for a plain numeric version 22" do
    with_recording_fake_pip do |script, recorded|
      result = PluginSpecHelper.run("pip", {
        "name"       => "pip",
        "version"    => "22",
        "executable" => script,
      })

      (result["failed"]?.try(&.as_bool) || false).must_equal(false)
      File.read(recorded).chomp.must_equal("pip==22")
    end
  end

  it "installs unpinned for an empty version string" do
    with_recording_fake_pip do |script, recorded|
      result = PluginSpecHelper.run("pip", {
        "name"       => "pip",
        "version"    => "",
        "executable" => script,
      })

      (result["failed"]?.try(&.as_bool) || false).must_equal(false)
      File.read(recorded).chomp.must_equal("pip")
    end
  end
end

# Writes a fake pip shell script that records every `install` argument
# (one per line, in order) and reports a successful install, hands the
# script and recording paths to the caller, and cleans up after.
private def with_recording_fake_pip(&)
  dir = File.join(Dir.tempdir, "krikri-pip-version-spec-#{Process.pid}-#{rand(100000)}")
  Dir.mkdir(dir)
  script = File.join(dir, "fakepip")
  recorded = File.join(dir, "install-args")
  body = %(#!/bin/sh\nif [ "$1" = "install" ]; then shift; printf '%s\\n' "$@" > #{Process.quote(recorded)}; echo "Successfully installed"; exit 0; fi\nexit 0\n)
  File.write(script, body)
  File.chmod(script, 0o755)
  begin
    yield script, recorded
  ensure
    File.delete(script)
    File.delete(recorded) if File.exists?(recorded)
    Dir.delete(dir)
  end
end
