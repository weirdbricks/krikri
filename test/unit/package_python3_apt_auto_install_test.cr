require "../minitest_helper"
require "file_utils"
require "json"

# Issue #433 (bodsch.dhcpd): `package: {name: [python3-apt], state: present}`
# on a host whose python3-apt bindings are MISSING reported changed=true while
# real ansible reports ok. Real apt.py (which `package:` delegates to on apt
# hosts) auto-installs the bindings at module start and then RESPAWNS - the
# respawned module re-runs the task against a host that now HAS python3-apt
# and exits changed=false, so the auto-install never shows up as a change.
# This engine's `package:` backend only emulated that module-start auto-install
# on the cache-refresh-only path (update_cache_only, the geerlingguy.kubernetes
# fix); the named-package path went straight to the dpkg-query installed check,
# found the REQUESTED python3-apt absent, and installed it as the requested
# package - changed=true, and through the registered `_installed.changed` it
# also made the role's only-on-change "clean apt cache" block run where
# Ansible skips it.
#
# The plugin binary is exercised for real against shimmed apt-get/dpkg-query
# on PATH (same pattern as package_apt_locate_miss_test.cr), because the
# module-start call site lives inside the plugin file whose bottom-of-file
# entry point defeats a plain require. The python3-apt probe itself uses the
# absolute /usr/bin/python3 (unshimable via PATH), so the `_python_apt_absent`
# spec seam (never set by real playbooks) forces the absent path on this dev
# box, which really has the bindings installed.
describe "package: python3-apt module-start auto-install (issue #433)" do
  serial!

  it "auto-installs python3-apt at module start and reports ok like the respawned module" do
    shim_dir = PluginSpecHelper.tmp_path("fake-python3-apt-autoinstall")
    Dir.mkdir_p(shim_dir)
    log_path = "#{shim_dir}/apt-get.log"
    flag_path = "#{shim_dir}/python3-apt.installed"

    # dpkg-query reports the requested name as NOT installed until the shimmed
    # `apt-get install -y python3-apt` (the auto-install) has run - mirroring
    # the respawned module's view of a host the bindings were just put on.
    dq_script = <<-SH
      #!/bin/sh
      if [ -f #{flag_path} ]; then
        echo "ii 2.7.7 python3-apt"
      fi
      SH
    File.write("#{shim_dir}/dpkg-query", dq_script)
    File.chmod("#{shim_dir}/dpkg-query", 0o755)

    # The shim records every invocation: the auto-install's `apt-get update`
    # prefetch and its `install -y python3-apt` are the module-start mutation;
    # the task's own install must NEVER run again afterwards (the respawn
    # sees python3-apt present and exits changed=false without an install).
    ag_script = <<-SH
      #!/bin/sh
      echo "$*" >> #{log_path}
      for arg in "$@"; do
        if [ "$arg" = "python3-apt" ]; then
          touch #{flag_path}
        fi
      done
      echo "Reading package lists..."
      echo "Building dependency tree..."
      echo "0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded."
      exit 0
      SH
    File.write("#{shim_dir}/apt-get", ag_script)
    File.chmod("#{shim_dir}/apt-get", 0o755)

    PluginSpecHelper::ENV_MUTEX.synchronize do
      old_path = ENV["PATH"]?
      ENV["PATH"] = "#{shim_dir}:#{old_path}"
      begin
        result = PluginSpecHelper.run("package",
          {"name"               => "python3-apt",
           "state"              => "present",
           "use"                => "apt",
           "_python_apt_absent" => "true"})
      ensure
        old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
      end

      result.as_h.has_key?("failed").must_equal(false)
      # Real ansible's respawned module reports ok (changed=false) here, not
      # the auto-install's changed=true.
      result["changed"].as_bool.must_equal(false)
      # The module-start auto-install really ran: update prefetch + install,
      # and nothing beyond them (no second install for the task itself).
      log = File.exists?(log_path) ? File.read(log_path) : ""
      apt_get_calls = log.split("\n").reject(&.empty?)
      apt_get_calls.size.must_equal(2)
      apt_get_calls.first.split(" ").first.must_equal("update")
      apt_get_calls.last.includes?("install").must_equal(true)
      apt_get_calls.last.includes?("python3-apt").must_equal(true)

      FileUtils.rm_r(shim_dir)
    end
  end

  it "fails the task when the auto-install itself fails" do
    shim_dir = PluginSpecHelper.tmp_path("fake-python3-apt-autoinstall-fail")
    Dir.mkdir_p(shim_dir)
    ag_script = <<-SH
      #!/bin/sh
      echo "E: Unable to locate package python3-apt" >&2
      exit 100
      SH
    File.write("#{shim_dir}/apt-get", ag_script)
    File.chmod("#{shim_dir}/apt-get", 0o755)

    PluginSpecHelper::ENV_MUTEX.synchronize do
      old_path = ENV["PATH"]?
      ENV["PATH"] = "#{shim_dir}:#{old_path}"
      begin
        result = PluginSpecHelper.run("package",
          {"name"               => "python3-apt",
           "state"              => "present",
           "use"                => "apt",
           "_python_apt_absent" => "true"})
      ensure
        old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
      end

      # Mirrors Ansible's check_rc=True hard failure on the auto-install:
      # the fail_json carries the RAW command result - msg is the stderr
      # with its trailing newline stripped (no "Failed to auto-install"
      # prefix), the reported cmd is apt.py's own resolved absolute
      # /usr/bin/apt-get path, and there is NO cache_updated key (the
      # module never got to touch the cache). The shim fails the `update`
      # prefetch first, so that is the stage being reported. The module
      # warned about the auto-install it was attempting before failing.
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("E: Unable to locate package python3-apt")
      result["cmd"].as_s.must_equal("/usr/bin/apt-get update")
      result["rc"].as_i.must_equal(100)
      result["stderr"].as_s.must_equal("E: Unable to locate package python3-apt\n")
      result["stderr_lines"].as_a.map(&.as_s).must_equal(["E: Unable to locate package python3-apt"])
      result["stdout"].as_s.must_equal("")
      result["stdout_lines"].as_a.empty?.must_equal(true)
      result["cache_updated"]?.must_be_nil
      result["warnings"].as_a.map(&.as_s).must_equal(
        ["Updating cache and auto-installing missing dependency: python3-apt"])

      FileUtils.rm_r(shim_dir)
    end
  end

  # The second auto-install stage (the install itself) reports the same
  # raw fail_json shape (issue #522: real ansible's msg is the failed
  # stage's stderr with no prefix, the cmd is apt.py's resolved absolute
  # /usr/bin/apt-get path, there is no cache_updated key, and the
  # python3-apt warning renders as the final "[WARNING]: ..." line). The
  # `apt` module's own call site has no `_python_apt_absent` seam (apt's
  # arg validation rejects unknown params, unlike package's), so this
  # drives the shared helper through package's path with the update
  # prefetch succeeding and the install failing.
  it "package module reports the raw failed-install shape when the auto-install install stage fails" do
    shim_dir = PluginSpecHelper.tmp_path("fake-python3-apt-autoinstall-install-fail")
    Dir.mkdir_p(shim_dir)
    log_path = "#{shim_dir}/apt-get.log"
    ag_script = <<-SH
      #!/bin/sh
      echo "$*" >> #{log_path}
      if [ "$1" = "update" ]; then
        echo "Hit:1 http://archive.ubuntu.com/ubuntu jammy InRelease"
        exit 0
      fi
      echo "E: Unable to locate package python3-apt" >&2
      exit 100
      SH
    File.write("#{shim_dir}/apt-get", ag_script)
    File.chmod("#{shim_dir}/apt-get", 0o755)

    PluginSpecHelper::ENV_MUTEX.synchronize do
      old_path = ENV["PATH"]?
      ENV["PATH"] = "#{shim_dir}:#{old_path}"
      begin
        result = PluginSpecHelper.run("package",
          {"name"               => "python3-apt",
           "state"              => "present",
           "use"                => "apt",
           "_python_apt_absent" => "true"})
      ensure
        old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
      end

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("E: Unable to locate package python3-apt")
      result["cmd"].as_s.must_equal("/usr/bin/apt-get install --no-install-recommends python3-apt -y -q")
      result["rc"].as_i.must_equal(100)
      result["stderr"].as_s.must_equal("E: Unable to locate package python3-apt\n")
      result["stderr_lines"].as_a.map(&.as_s).must_equal(["E: Unable to locate package python3-apt"])
      result["cache_updated"]?.must_be_nil
      result["warnings"].as_a.map(&.as_s).must_equal(
        ["Updating cache and auto-installing missing dependency: python3-apt"])
      # The prefetch ran and succeeded before the install failed.
      calls = File.read(log_path).split("\n").reject(&.empty?)
      calls.size.must_equal(2)
      calls.first.must_equal("update")

      FileUtils.rm_r(shim_dir)
    end
  end
end
