require "../minitest_helper"
require "json"

# Issue #767 (kpg dnf5 happy path): on a Rocky 10 target real ansible's
# dnf5 module cannot even start - dnf5.py's _ensure_dnf fails to import the
# libdnf5 python bindings, then (auto_install_module_deps defaulting to
# true) runs `dnf install -y python3-libdnf5` through check_rc=True, and
# Rocky 10's repos carry no python3-libdnf5, so EVERY dnf5 task dies there
# with the raw run_command failure as the task's whole result. This engine's
# native dnf5 plugin skipped that bootstrap entirely and went straight to
# its own dnf5 CLI work - reporting ok where real failed. The plugin binary
# is exercised for real against shimmed dnf/dnf5 on PATH (same pattern as
# package_python3_apt_auto_install_test.cr); the import probe itself uses
# absolute interpreter paths (unshimmable via PATH), so the `_libdnf5_probe`
# spec seam (never set by real playbooks) forces the probe's answer.
describe "dnf5: libdnf5 python-bindings bootstrap (issue #767)" do
  it "auto-installs python3-libdnf5 at module start and proceeds like the respawned module" do
    shim_dir = PluginSpecHelper.tmp_path("fake-libdnf5-autoinstall")
    Dir.mkdir_p(shim_dir)
    dnf_log = "#{shim_dir}/dnf.log"
    dnf5_log = "#{shim_dir}/dnf5.log"

    # The bootstrap's `dnf install -y python3-libdnf5` is the module-start
    # mutation; the task's own work (here the cache refresh through the
    # dnf5 binary) must only run AFTER it, like real's respawned module.
    dnf_script = <<-SH
      #!/bin/sh
      echo "$*" >> #{dnf_log}
      echo "Last metadata expiration check: 0:01:07 ago on Tue Nov  3 11:21:56 2026."
      echo "Installed: python3-libdnf5-5.2.0.0-1.el10.noarch"
      exit 0
      SH
    File.write("#{shim_dir}/dnf", dnf_script)
    File.chmod("#{shim_dir}/dnf", 0o755)

    dnf5_script = <<-SH
      #!/bin/sh
      echo "$*" >> #{dnf5_log}
      exit 0
      SH
    File.write("#{shim_dir}/dnf5", dnf5_script)
    File.chmod("#{shim_dir}/dnf5", 0o755)

    result = PluginSpecHelper.run("dnf5",
      {"update_cache"   => "true",
       "_libdnf5_probe" => "absent-then-present"},
      env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]}"})

    result.as_h.has_key?("failed").must_equal(false)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Cache updated")

    # Exactly one bootstrap install ran, before any dnf5 work.
    dnf_calls = File.read(dnf_log).split("\n").reject(&.empty?)
    dnf_calls.size.must_equal(1)
    dnf_calls.first.must_equal("install -y python3-libdnf5")
    dnf5_calls = File.read(dnf5_log).split("\n").reject(&.empty?)
    dnf5_calls.size.must_equal(1)
    dnf5_calls.first.must_equal("makecache")

    FileUtils.rm_r(shim_dir)
  end

  it "fails with the raw run_command shape when the bootstrap install fails" do
    shim_dir = PluginSpecHelper.tmp_path("fake-libdnf5-autoinstall-fail")
    Dir.mkdir_p(shim_dir)
    dnf5_log = "#{shim_dir}/dnf5.log"
    dnf_script = <<-SH
      #!/bin/sh
      echo "Last metadata expiration check: 0:01:07 ago on Tue Nov  3 11:21:56 2026."
      echo "No match for argument: python3-libdnf5"
      echo "Error: Unable to find a match: python3-libdnf5" >&2
      exit 1
      SH
    File.write("#{shim_dir}/dnf", dnf_script)
    File.chmod("#{shim_dir}/dnf", 0o755)
    dnf5_script = <<-SH
      #!/bin/sh
      echo "$*" >> #{dnf5_log}
      SH
    File.write("#{shim_dir}/dnf5", dnf5_script)
    File.chmod("#{shim_dir}/dnf5", 0o755)

    result = PluginSpecHelper.run("dnf5",
      {"name"           => "sed",
       "state"          => "present",
       "_libdnf5_probe" => "absent"},
      env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]}"})

    # Mirrors Ansible's check_rc=True hard failure on the bootstrap: the
    # fail_json carries the RAW command result - msg is the stderr with its
    # trailing newline stripped (no prefix), the reported cmd is dnf5.py's
    # own bare "dnf ..." argv string, and the module never reached its own
    # package work (the dnf5 shim log stays empty). dnf5.py emits no
    # warning before the install attempt, so there is no warnings key.
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Error: Unable to find a match: python3-libdnf5")
    result["cmd"].as_s.must_equal("dnf install -y python3-libdnf5")
    result["rc"].as_i.must_equal(1)
    result["stderr"].as_s.must_equal("Error: Unable to find a match: python3-libdnf5\n")
    result["stderr_lines"].as_a.map(&.as_s).must_equal(["Error: Unable to find a match: python3-libdnf5"])
    result["stdout"].as_s.must_equal(
      "Last metadata expiration check: 0:01:07 ago on Tue Nov  3 11:21:56 2026.\nNo match for argument: python3-libdnf5\n")
    result["stdout_lines"].as_a.map(&.as_s).must_equal([
      "Last metadata expiration check: 0:01:07 ago on Tue Nov  3 11:21:56 2026.",
      "No match for argument: python3-libdnf5",
    ])
    result["warnings"]?.must_be_nil
    # The module never reached its own package work: the dnf5 shim was
    # never invoked (its log only appears on an invocation).
    File.exists?(dnf5_log).must_equal(false)

    FileUtils.rm_r(shim_dir)
  end

  it "reports run_command's OSError shape when no dnf binary exists" do
    # An empty PATH: the bootstrap's bare `dnf` never starts, which real
    # surfaces as run_command's caught OSError - rc=errno (2), empty
    # stdout/stderr(+_lines), the bare "Error executing command." fatal msg,
    # and the Errno text riding the [ERROR] block via _ansible_error_detail.
    empty_dir = PluginSpecHelper.tmp_path("no-dnf-anywhere")
    Dir.mkdir_p(empty_dir)

    result = PluginSpecHelper.run("dnf5",
      {"name"           => "sed",
       "state"          => "present",
       "_libdnf5_probe" => "absent"},
      env: {"PATH" => empty_dir})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Error executing command.")
    result["cmd"].as_s.must_equal("dnf install -y python3-libdnf5")
    result["rc"].as_i.must_equal(2)
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.must_equal("")
    result["stdout_lines"].as_a.empty?.must_equal(true)
    result["stderr_lines"].as_a.empty?.must_equal(true)
    result["_ansible_error_detail"].as_s.must_equal(
      "Error executing command: [Errno 2] No such file or directory: b'dnf'")
  end

  it "refuses check mode when the bindings are missing instead of installing them" do
    result = PluginSpecHelper.run("dnf5",
      {"name"                => "sed",
       "state"               => "present",
       "_ansible_check_mode" => "true",
       "_libdnf5_probe"      => "absent"})

    # The auto-install is a real host mutation; dnf5.py fails check mode
    # fast with this exact message instead (apt's mirror: apt_lock_retry's
    # CHECK_MODE_NO_PYTHON_APT_MSG).
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(
      "python3-libdnf5 must be installed to use check mode. If run normally this module can auto-install it, " \
      "see the auto_install_module_deps option.")
  end

  it "fails with the could-not-import message when auto_install_module_deps is false" do
    result = PluginSpecHelper.run("dnf5",
      {"name"                     => "sed",
       "state"                    => "present",
       "auto_install_module_deps" => "false",
       "_libdnf5_probe"           => "absent"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_include("Could not import the libdnf5 python module using ")
    result["msg"].as_s.must_include(
      "(attempted ['/usr/libexec/platform-python', '/usr/bin/python3', '/usr/bin/python']).")
  end

  it "skips the bootstrap entirely when the bindings import" do
    shim_dir = PluginSpecHelper.tmp_path("fake-libdnf5-present")
    Dir.mkdir_p(shim_dir)
    dnf_log = "#{shim_dir}/dnf.log"
    dnf5_log = "#{shim_dir}/dnf5.log"
    dnf_script = <<-SH
      #!/bin/sh
      echo "$*" >> #{dnf_log}
      SH
    File.write("#{shim_dir}/dnf", dnf_script)
    File.chmod("#{shim_dir}/dnf", 0o755)
    dnf5_script = <<-SH
      #!/bin/sh
      echo "$*" >> #{dnf5_log}
      exit 0
      SH
    File.write("#{shim_dir}/dnf5", dnf5_script)
    File.chmod("#{shim_dir}/dnf5", 0o755)

    result = PluginSpecHelper.run("dnf5",
      {"update_cache"   => "true",
       "_libdnf5_probe" => "present"},
      env: {"PATH" => "#{shim_dir}:#{ENV["PATH"]}"})

    result.as_h.has_key?("failed").must_equal(false)
    result["msg"].as_s.must_equal("Cache updated")
    # No bootstrap ran - the bindings were already importable.
    File.exists?(dnf_log).must_equal(false)
    dnf5_calls = File.read(dnf5_log).split("\n").reject(&.empty?)
    dnf5_calls.size.must_equal(1)
    dnf5_calls.first.must_equal("makecache")

    FileUtils.rm_r(shim_dir)
  end
end
