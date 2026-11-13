require "../minitest_helper"

# Regression spec for issue #1203 (deveth0.oracle-java's "Install Java
# Package" check phase, round 29909286): real apt_repository's
# module-start !HAVE_PYTHON_APT ladder auto-installs the python3-apt
# bindings on a host that has apt-get, which is a persistent host
# mutation. A later `apt:` task in check mode therefore resolves its
# cache and fails "No package matching '...' is available" on Ansible's
# host, while krikri's host - which never performed the install, its own
# implementation being native - still lacked the bindings and failed
# with apt.py's check-mode refusal instead.
#
# The ladder mirrors apt_repository.py's install_python_apt(): one
# absolute-path `apt-get update`, then `apt-get install python3-apt -y
# -q`; a failed command becomes fail_json carrying only its stripped
# stderr. `_python_apt_absent` forces the probe's answer and
# `_apt_get_paths` substitutes a recording apt-get stub, so the spec
# never installs anything or touches the network.
describe "apt_repository python3-apt auto-install (apt-get present)" do
  it "runs apt-get update then the python3-apt install before continuing" do
    log = PluginSpecHelper.tmp_path("apt-get.log")
    stub = PluginSpecHelper.tmp_path("apt-get")
    File.write(stub, "#!/bin/sh\necho \"$@\" >> #{log}\nexit 0\n")
    File.chmod(stub, 0o755)

    result = PluginSpecHelper.run("apt_repository", {
      "repo"               => "deb https://packages.totally-fake-example.com/repo stable main",
      "_apt_get_paths"     => stub,
      "_python_apt_absent" => "true",
    })

    File.read(log).lines.map(&.strip).must_equal([
      "update",
      "install python3-apt -y -q",
    ])
    # The forced-absent probe stays absent after the install, so this is
    # the ladder's own final message - never a silent success.
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_match(/\Apython3-apt must be installed and visible from .+\.\z/)
  end

  it "fails with the update attempt's stripped stderr when apt-get update fails" do
    stub = PluginSpecHelper.tmp_path("apt-get-fail-update")
    File.write(stub, "#!/bin/sh\necho 'E: simulated update failure' >&2\nexit 100\n")
    File.chmod(stub, 0o755)

    result = PluginSpecHelper.run("apt_repository", {
      "repo"               => "deb https://packages.totally-fake-example.com/repo stable main",
      "_apt_get_paths"     => stub,
      "_python_apt_absent" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Failed to auto-install python3-apt. Error was: 'E: simulated update failure'")
    result["cmd"]?.must_be_nil
    result["rc"]?.must_be_nil
  end

  it "fails with the install attempt's stderr when the install itself fails" do
    marker = PluginSpecHelper.tmp_path("apt-get-install-ran")
    stub = PluginSpecHelper.tmp_path("apt-get-fail-install")
    File.write(stub, "#!/bin/sh\n" \
                     "if [ \"$1\" = install ]; then\n" \
                     "  echo ran > #{marker}\n" \
                     "  echo 'E: simulated install failure' >&2\n" \
                     "  exit 100\n" \
                     "fi\n" \
                     "exit 0\n")
    File.chmod(stub, 0o755)

    result = PluginSpecHelper.run("apt_repository", {
      "repo"               => "deb https://packages.totally-fake-example.com/repo stable main",
      "_apt_get_paths"     => stub,
      "_python_apt_absent" => "true",
    })

    File.exists?(marker).must_equal(true)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to auto-install python3-apt. Error was: 'E: simulated install failure'")
  end

  it "refuses check mode before attempting any install" do
    marker = PluginSpecHelper.tmp_path("apt-get-check-mode-ran")
    stub = PluginSpecHelper.tmp_path("apt-get-check-mode")
    File.write(stub, "#!/bin/sh\necho ran > #{marker}\nexit 0\n")
    File.chmod(stub, 0o755)

    result = PluginSpecHelper.run("apt_repository", {
      "repo"                => "deb https://packages.totally-fake-example.com/repo stable main",
      "_apt_get_paths"      => stub,
      "_python_apt_absent"  => "true",
      "_ansible_check_mode" => "true",
    })

    File.exists?(marker).must_equal(false)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("python3-apt must be installed to use check mode. If run normally this module can auto-install it.")
  end
end
