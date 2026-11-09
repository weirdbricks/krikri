require "../minitest_helper"
require "file_utils"

# Regression spec for apt.py's mark_installed(m, package_names,
# manual=True) call at the end of install(): the `apt` module always
# ends a state=present/state=latest run with `apt-mark manual <names>`,
# and that command's own failure is a fail_json of its own shape which
# PREEMPTS the install result install() was about to return. `package:`
# forwards to the apt module in real ansible, so its apt backend carries
# the same trailing call.
#
# Found on grycap.weave (round 1794194103, issue #1023): its
# NVIDIA.nvidia_driver "install driver packages" loop ran on a host that
# had filled its disk, and every item where the trailing apt-mark failed
# reported "Command '/usr/bin/apt-mark manual <pkg>' failed." from real
# ansible-playbook while krikri-playbook reported apt-get's own failure
# (or plain ok) instead - same task results on the failing items,
# different msg/rc/stderr and, where the whole item was a no-op, a
# different failed state entirely.
#
# A stub PATH is used instead of a real apt-mark so both branches are
# reachable without root: the shim fails the way apt-mark does when it
# cannot write /var/lib/apt/extended_states.

private def with_apt_mark_shim(mark_rc : Int32, mark_stderr : String, dpkg_status : String = "ii",
                               apt_get_rc : Int32 = 0, apt_get_stderr : String = "", &) : Nil
  dir = File.join(Dir.tempdir, "krikri-apt-mark-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "dpkg-query"), "#!/bin/sh\necho \"$KRIKRI_DPKG_STATUS 1.0-1 $3\"\n")
  apt_get = apt_get_rc == 0 ? "#!/bin/sh\nexit 0\n" : "#!/bin/sh\nprintf '%b' \"#{apt_get_stderr.gsub("\"", "\\\"")}\" >&2\nexit #{apt_get_rc}\n"
  File.write(File.join(dir, "apt-get"), apt_get)
  File.write(File.join(dir, "apt-cache"), "#!/bin/sh\nprintf '%s:\\n  Installed: 1.0-1\\n  Candidate: 1.0-1\\n  Version table:\\n' \"$2\"\n")
  File.write(File.join(dir, "stat"), "#!/bin/sh\ndate +%s\n")
  File.write(File.join(dir, "apt-mark"), "#!/bin/sh\nprintf '%b' \"#{mark_stderr.gsub("\"", "\\\"")}\" >&2\nexit #{mark_rc}\n")
  {"dpkg-query", "apt-get", "apt-cache", "stat", "apt-mark"}.each { |bin| File.chmod(File.join(dir, bin), 0o755) }
  yield dir, {"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_DPKG_STATUS" => dpkg_status}.to_json
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "apt plugin trailing apt-mark manual call (apt.py's mark_installed)" do
  # The exact apt-mark text a full disk / unwritable dpkg state produces.
  APT_MARK_EXTENDED_STATES_STDERR = "E: Could not create temporary file for /var/lib/apt/extended_states - mkstemp (13: Permission denied)\nE: Failed to write temporary StateFile /var/lib/apt/extended_states\n"

  # The apt-get failure text of the round-1794194103 capture's item 2.
  APT_GET_NO_SPACE_STDERR = "E: You don't have enough free space in /var/cache/apt/archives/.\n"

  it "fails the task with apt-mark's own message, preempting the install result" do
    with_apt_mark_shim(100, APT_MARK_EXTENDED_STATES_STDERR) do |dir, env|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-fake-pkg",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Command '#{dir}/apt-mark manual krikri-fake-pkg' failed.")
      result["rc"].as_i.must_equal(100)
      result["stderr"].as_s.must_equal(APT_MARK_EXTENDED_STATES_STDERR)
      result["stdout"].as_s.must_equal("")
      result["stdout_lines"].as_a.size.must_equal(0)
      result["stderr_lines"].as_a.size.must_equal(2)
      # fail_json(msg=, stdout=, stderr=, rc=) puts the kwargs first,
      # appends failed/msg after them, and _return_formatted derives the
      # <key>_lines companions; mark_installed exits before main() can
      # append cache_updated/cache_update_time. The controller's failed
      # backfill (changed, exception) trails these, so the plugin-side
      # order is asserted only up to the module's own keys.
      result.as_h.keys.first(7).must_equal(["stdout", "stderr", "rc", "failed", "msg", "stdout_lines", "stderr_lines"])
    end
  end

  it "marks the base name of a pinned spec and leaves an apt-mark success unremarked" do
    with_apt_mark_shim(0, "") do |_dir, env|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-fake-pkg=1.0-1",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"]?.must_be_nil
      result["changed"].as_bool.must_equal(false)
      # Nothing reached apt-get: the already-installed exit keeps its
      # bare shape, exactly as before the trailing apt-mark call.
      result["msg"]?.must_be_nil
      result["stdout"]?.must_be_nil
      result.as_h.keys.must_equal(["changed", "cache_updated", "cache_update_time"])
    end
  end

  it "preempts a failed apt-get install with the trailing apt-mark failure" do
    with_apt_mark_shim(100, APT_MARK_EXTENDED_STATES_STDERR, dpkg_status: "un",
      apt_get_rc: 100, apt_get_stderr: APT_GET_NO_SPACE_STDERR) do |dir, env|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-fake-pkg",
        "state"        => "present",
        "_environment" => env,
      })

      # apt-get's own "'cmd' failed" result was about to be returned;
      # the mark failure takes its place (round-1794194103 items 1/3:
      # ansible reported the apt-mark message, this engine apt-get's).
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Command '#{dir}/apt-mark manual krikri-fake-pkg' failed.")
      result["rc"].as_i.must_equal(100)
      result["stderr"].as_s.must_equal(APT_MARK_EXTENDED_STATES_STDERR)
    end
  end

  it "lets a failed apt-get install result stand when the trailing apt-mark succeeds" do
    with_apt_mark_shim(0, "", dpkg_status: "un",
      apt_get_rc: 100, apt_get_stderr: APT_GET_NO_SPACE_STDERR) do |dir, env|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-fake-pkg",
        "state"        => "present",
        "_environment" => env,
      })

      # round-1794194103 item 2: the install failure carries apt.py's
      # eight-slot command and the cache keys, unchanged by the mark.
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("#{dir}/apt-get -y ")
      result["msg"].as_s.must_include("install 'krikri-fake-pkg=1.0-1'' failed: #{APT_GET_NO_SPACE_STDERR}")
      result["rc"].as_i.must_equal(100)
      result["cache_updated"].as_bool.must_equal(false)
      result.as_h.keys.first(9).must_equal(["stdout", "stderr", "rc", "cache_updated", "cache_update_time", "failed", "msg", "stdout_lines", "stderr_lines"])
    end
  end

  it "preempts the state=latest install failure with the trailing apt-mark failure" do
    with_apt_mark_shim(100, APT_MARK_EXTENDED_STATES_STDERR, dpkg_status: "un",
      apt_get_rc: 100, apt_get_stderr: APT_GET_NO_SPACE_STDERR) do |dir, env|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-fake-pkg",
        "state"        => "latest",
        "_environment" => env,
      })

      # state=latest flows through apt.py's install() with upgrade=True,
      # so its rc!=0 result is preempted by the same trailing mark.
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Command '#{dir}/apt-mark manual krikri-fake-pkg' failed.")
    end
  end

  it "preempts the state=latest no-op result with the trailing apt-mark failure" do
    with_apt_mark_shim(100, APT_MARK_EXTENDED_STATES_STDERR) do |dir, env|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-fake-pkg",
        "state"        => "latest",
        "_environment" => env,
      })

      # The exit where apt-get itself was reached and found nothing to
      # do - real still marks on the way out, and that fail_json
      # preempts the "upgraded to latest"/"already at latest" result
      # just like the all-already-installed present exit.
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Command '#{dir}/apt-mark manual krikri-fake-pkg' failed.")
    end
  end
end

describe "package plugin trailing apt-mark manual call (package: delegates to apt)" do
  APT_MARK_STDERR = "E: Could not create temporary file for /var/lib/apt/extended_states - mkstemp (13: Permission denied)\nE: Failed to write temporary StateFile /var/lib/apt/extended_states\n"

  # The apt-get failure text of the round-1794194103 capture's item 2.
  APT_GET_NO_SPACE_STDERR = "E: You don't have enough free space in /var/cache/apt/archives/.\n"

  it "fails an already-satisfied package: with the trailing apt-mark message" do
    with_apt_mark_shim(100, APT_MARK_STDERR) do |dir, env|
      result = PluginSpecHelper.run("package", {
        "name"         => "krikri-fake-pkg",
        "state"        => "present",
        "use"          => "apt",
        "_environment" => env,
      })

      # real `package:` forwards to the apt module, whose install() marks
      # even the all-already-satisfied list (round-1794194103 item 4:
      # ansible failed where this engine reported ok).
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Command '#{dir}/apt-mark manual krikri-fake-pkg' failed.")
      result["rc"].as_i.must_equal(100)
      result["stderr"].as_s.must_equal(APT_MARK_STDERR)
    end
  end

  it "preempts a failed package: install with the trailing apt-mark failure" do
    with_apt_mark_shim(100, APT_MARK_STDERR, dpkg_status: "un",
      apt_get_rc: 100, apt_get_stderr: APT_GET_NO_SPACE_STDERR) do |dir, env|
      result = PluginSpecHelper.run("package", {
        "name"         => "krikri-fake-pkg",
        "state"        => "present",
        "use"          => "apt",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Command '#{dir}/apt-mark manual krikri-fake-pkg' failed.")
    end
  end
end
