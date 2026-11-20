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

  # The chaos loop's rename clash (issue #1344, kpg
  # 000023/000026-multi-dpkg_divert-chaos): dpkg-divert refuses to rename
  # onto an existing diversion target, and real's fail_json passes the
  # command, its exit status and the diversion alongside the message - a
  # registered loop item and the fatal dump both carry them. Driven
  # through a stand-in dpkg-divert on the plugin's PATH so no diversion
  # database is touched.
  it "carries cmd, rc and diversion on a forced-rename clash" do
    shim_dir = PluginSpecHelper.tmp_path("dpkg-divert-clash-bin")
    Dir.mkdir_p(shim_dir)
    shim = File.join(shim_dir, "dpkg-divert")
    File.write(shim, <<-SH)
      #!/bin/sh
      case "$1" in
        --version) echo "Debian dpkg-divert version 1.22.22 (amd64)."; exit 0 ;;
        --listpackage) exit 0 ;;
      esac
      echo "dpkg-divert: error: 'diversion of a to b by dhyeer' clashes with 'diversion of c to b by dhyeer'" >&2
      exit 2
      SH
    File.chmod(shim, 0o755)

    src = PluginSpecHelper.tmp_path("kpg1344-src.txt")
    target = PluginSpecHelper.tmp_path("kpg1344-out2.txt")
    File.write(src, "one\n")
    File.write(target, "already there\n")

    result = PluginSpecHelper.run("dpkg_divert", {
      "path"   => src,
      "state"  => "present",
      "divert" => target,
      "holder" => "dhyeer",
      "rename" => "true",
    }, {} of String => String, "localhost",
      env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]? || "/usr/bin:/bin"}"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Set 'force' param to True to force renaming of files.")
    result["rc"].as_i.must_equal(2)
    result["cmd"].as_s.must_equal("#{shim} --rename --package dhyeer --divert #{target} --add #{src}")
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.includes?("clashes with").must_equal(true)
    # The controller derives these two for its dump of a failed result.
    result["stdout_lines"].as_a.must_equal([] of JSON::Any)
    result["stderr_lines"].as_a.size.must_equal(1)
    result["diversion"].as_h["state"].as_s.must_equal("absent")
    result["diversion"].as_h["path"].as_s.must_equal(src)
  end

  # Under --diff real dpkg_divert.py attaches {before, after} diversion
  # dicts and ansible's callback prints them as a before/after block ahead
  # of the task's status line - in check mode too, where `after` is the
  # wanted diversion because the module only re-reads the real one
  # outside check mode (kpg 000016-multi-cpanm-happy: Ansible printed the
  # block for every dpkg_divert loop item while krikri printed the
  # changed line alone).
  it "reports the before/after diversion pair under --diff in check mode" do
    skip "no dpkg-divert on this machine" unless File.exists?("/usr/bin/dpkg-divert") || File.exists?("/usr/sbin/dpkg-divert")

    path = PluginSpecHelper.tmp_path("kpg1639-divert.txt")
    result = PluginSpecHelper.run("dpkg_divert", {
      "path"                => path,
      "state"               => "present",
      "_ansible_check_mode" => "true",
      "_ansible_diff"       => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["diff"]["before"]["state"].as_s.must_equal("absent")
    result["diff"]["before"]["divert"].raw.must_be_nil
    result["diff"]["after"]["state"].as_s.must_equal("present")
    result["diff"]["after"]["divert"].as_s.must_equal("#{path}.distrib")
  end
end
