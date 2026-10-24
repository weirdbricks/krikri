require "../minitest_helper"

# Regression spec for issue #296 (mats116.java8 on Rocky 9.6, round
# round29880189): what apt_repository must fail with on a target that has
# no apt-get at all. Real ansible-core 2.19.11's !HAVE_PYTHON_APT ladder
# in main() never touches a source file there - it fails along check
# mode / install_python_apt=False / the final "python3-apt must be
# installed and visible from <sys.executable>." - while the guard here
# used to report apt.py's own exec-failure shape (`cmd: update`, msg
# "Error executing command.", `rc: 2`, keys real's apt_repository never
# produces in this path). `_apt_get_paths` (comma-separated) forces that
# gate to fire even on a dev box that really has apt-get - `_`-prefixed
# params are spec-seam-only (Ansible has no such params and would reject
# them in a real playbook).
describe "apt_repository python3-apt gate (no apt-get)" do
  it "fails check mode with the can-auto-install message" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"                => "deb https://packages.totally-fake-example.com/repo stable main",
      "_apt_get_paths"      => "/nonexistent-krikri-spec/apt-get,/nonexistent-krikri-spec/apt-get-local",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("python3-apt must be installed to use check mode. If run normally this module can auto-install it.")
  end

  it "names install_python_apt=False when the param is explicitly false" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"               => "deb https://packages.totally-fake-example.com/repo stable main",
      "_apt_get_paths"     => "/nonexistent-krikri-spec/apt-get",
      "install_python_apt" => "false",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("python3-apt is not installed, and install_python_apt is False")
  end

  it "points at the discovered target python in the default install_python_apt case" do
    result = PluginSpecHelper.run("apt_repository", {
      "repo"           => "deb https://packages.totally-fake-example.com/repo stable main",
      "_apt_get_paths" => "/nonexistent-krikri-spec/apt-get",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    # The interpreter path is the one real reports - the target's own
    # discovered python (e.g. /usr/bin/python3.9 live on Rocky) - so the
    # exact tail is host-dependent here; the message shape is not:
    # real's final fail_json ends that sentence with a period.
    result["msg"].as_s.must_match(/\Apython3-apt must be installed and visible from .+\.\z/)
    # Real fail_json carries no cmd/rc - exactly what the old guard's
    # {"cmd": "update", "rc": 2} shape used to fabricate.
    result["cmd"]?.must_be_nil
    result["rc"]?.must_be_nil
  end
end
