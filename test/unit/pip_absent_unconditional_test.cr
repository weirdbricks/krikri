require "../minitest_helper"

# Regression spec for pip's state=absent path, added in 0.9.1095.
# Found via the podman-diff harness
# (testing/podman-diff/cases/pip_edge_cases.yml, case Q5):
# Ansible's pip module runs `pip uninstall` UNCONDITIONALLY and lets
# pip's own "not installed" output line decide changed=false - it does
# not pre-check installed-ness locally. This engine used to skip the
# invocation entirely when a local `pip show` said the package was
# absent, which made a PEP 668 externally-managed environment (bookworm
# system python, where pip refuses to run at all) report state=absent
# as ok where ansible-playbook fails the task.
#
# Driven through the real plugin binary via PluginSpecHelper with a
# fake pip executable so the spec is hermetic: no real pip, no network,
# no mutation of the dev machine's python environment.
describe "pip: state=absent runs pip unconditionally" do
  it "reports changed=false from pip's own 'not installed' output line" do
    with_fake_pip("uninstall-ok-not-installed") do |script|
      result = PluginSpecHelper.run("pip", {
        "name"       => "krikri-no-such-package-zzz",
        "state"      => "absent",
        "executable" => script,
      })

      (result["failed"]?.try(&.as_bool) || false).must_equal(false)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_include("already absent")
    end
  end

  it "reports changed=true when pip actually removes something" do
    with_fake_pip("uninstall-removed") do |script|
      result = PluginSpecHelper.run("pip", {
        "name"       => "krikri-no-such-package-zzz",
        "state"      => "absent",
        "executable" => script,
      })

      (result["failed"]?.try(&.as_bool) || false).must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("removed")
    end
  end

  it "fails when the uninstall invocation itself fails (PEP 668 refusal)" do
    with_fake_pip("uninstall-fails") do |script|
      result = PluginSpecHelper.run("pip", {
        "name"       => "krikri-no-such-package-zzz",
        "state"      => "absent",
        "executable" => script,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_include("externally-managed-environment")
    end
  end

  # Issue #946: a non-zero uninstall must surface the way Ansible's pip.py
  # _fail() reports it - `cmd` carrying the exact argv it ran, and `msg`
  # built from stdout/stderr ("\n:stderr: ..." when stdout is empty) -
  # rather than krikri's old bespoke "Failed to uninstall:" prefix with no
  # cmd key. Verified byte-for-byte against real ansible-core 2.21.6.
  it "reports an uninstall failure as cmd + stderr-tagged msg like Ansible's _fail" do
    with_fake_pip("uninstall-fails") do |script|
      result = PluginSpecHelper.run("pip", {
        "name"       => "krikri-no-such-package-zzz",
        "state"      => "absent",
        "executable" => script,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["cmd"].as_a.map(&.as_s).must_equal([script, "uninstall", "-y", "krikri-no-such-package-zzz"])
      msg = result["msg"].as_s
      msg.must_include("\n:stderr: error: externally-managed-environment")
      msg.includes?("Failed to uninstall").must_equal(false)
    end
  end
end

# Writes a fake pip shell script whose behavior the uninstall branch
# observes, hands the absolute path to the caller, and cleans up after.
private def with_fake_pip(mode : String, &)
  dir = File.join(Dir.tempdir, "krikri-pip-spec-#{Process.pid}-#{rand(100000)}")
  Dir.mkdir(dir)
  script = File.join(dir, "fakepip")
  body = case mode
         when "uninstall-ok-not-installed"
           %(#!/bin/sh\nif [ "$1" = "uninstall" ]; then echo "WARNING: Skipping krikri-no-such-package-zzz as it is not installed."; exit 0; fi\necho "Successfully installed krikri-no-such-package-zzz"\nexit 0\n)
         when "uninstall-removed"
           %(#!/bin/sh\nif [ "$1" = "uninstall" ]; then echo "Successfully uninstalled krikri-no-such-package-zzz"; exit 0; fi\necho "Successfully installed krikri-no-such-package-zzz"\nexit 0\n)
         else
           %(#!/bin/sh\nif [ "$1" = "uninstall" ]; then echo "error: externally-managed-environment" >&2; exit 1; fi\nexit 0\n)
         end
  File.write(script, body)
  File.chmod(script, 0o755)
  begin
    yield script
  ensure
    File.delete(script)
    Dir.delete(dir)
  end
end
