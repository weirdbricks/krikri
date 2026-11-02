require "../minitest_helper"

# dpkg_divert's parameter-validation failures, exercised before anything
# shells out. The read-only status check below only runs when dpkg-divert
# itself is installed; actually adding/removing a diversion mutates the
# real dpkg database and belongs to the live benchmark rounds.
describe "dpkg_divert plugin" do
  it "fails when path is missing" do
    result = PluginSpecHelper.run("dpkg_divert", {"state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("path")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("dpkg_divert", {"path" => "/etc/hosts", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("state must be 'present' or 'absent'")
  end

  it "reports an unmodified absence for a never-diverted path" do
    skip "no dpkg-divert on this machine" unless File.exists?("/usr/bin/dpkg-divert") || File.exists?("/usr/sbin/dpkg-divert")

    result = PluginSpecHelper.run("dpkg_divert", {"path" => "/etc/hostname", "state" => "absent"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
  end

  # Real's diversion_state lookup runs dpkg-divert --listpackage through
  # run_command(check_rc=True), so a non-absolute path (dpkg-divert's
  # own usage error, rc=2) fails the module RIGHT THERE with
  # run_command's shape - msg is the bare stderr, cmd the resolved
  # binary - instead of reaching the main command's "Unexpected error
  # while changing state of the diversion." branch (issue #748, kpg
  # 000005/000008-dpkg_divert-chaos).
  it "fails at the diversion lookup with run_command's check_rc shape on a non-absolute path" do
    skip "no dpkg-divert on this machine" unless File.exists?("/usr/bin/dpkg-divert") || File.exists?("/usr/sbin/dpkg-divert")

    result = PluginSpecHelper.run("dpkg_divert", {"path" => "80", "state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["rc"].as_i.must_equal(2)
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.must_include("is not absolute")
    result["msg"].as_s.must_equal(result["stderr"].as_s.rstrip)
    # fail_json's cmd is _clean_args' rendering of the run_command argv:
    # the RESOLVED dpkg-divert path with shlex.quote-joined args - a
    # safe token like `80` stays bare.
    result["cmd"].as_s.must_match(%r{\A/\S+/dpkg-divert --listpackage 80\z})
    result["msg"].as_s.includes?("Unexpected error while changing state").must_equal(false)
  end
end
