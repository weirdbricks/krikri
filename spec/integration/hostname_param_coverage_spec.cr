require "../spec_helper"
require "file_utils"

# Proactive parameter-coverage pass for the hostname module's `use:`
# parameter (real Ansible's STRATS dict: alpine/debian/freebsd/generic/
# macos/macosx/darwin/openbsd/openrc/redhat/sles/solaris/systemd).
#
# Every asserted failure text was live-verified against real
# ansible-core 2.19.4's own
# /usr/lib/python3/dist-packages/ansible/modules/hostname.py, run
# directly inside a rockylinux:9 container via
#   printf '{"ANSIBLE_MODULE_ARGS": {...}}' | python3 hostname.py
#   ("value of use must be one of: alpine, debian, freebsd, generic,
#    macos, macosx, darwin, openbsd, openrc, redhat, sles, solaris,
#    systemd, got: bogus" - choices in STRATS insertion order)
#   "missing required arguments: name" (checked before choice validation)
#   use=generic: raw NotImplementedError traceback (no JSON at all)
#   use=redhat without a HOSTNAME entry (missing file included, check
#    mode included): "Unable to locate HOSTNAME entry in
#    /etc/sysconfig/network"
#   use=systemd/debian command order (shimmed hostnamectl):
#    --transient status, --static status, then permanent-first sets:
#    --pretty --static set-hostname N, --transient set-hostname N
#   use=systemd >64-char name: "name cannot be longer than 64 characters
#    on systemd servers, try a shorter name" - but ONLY on the actual
#    set; check mode reports would-change (live-verified)
#   use=systemd without hostnamectl: "Failed to find required executable
#    \"hostnamectl\" in paths: <PATH>:/sbin:/usr/sbin:/usr/local/sbin"
#   use=systemd failing hostnamectl: "Command failed rc=1, out=, err=..."
#   use=alpine: exactly ONE command, `hostname -F /etc/hostname`, run
#    BEFORE the file write (AlpineStrategy extends FileStrategy, so
#    set_current_hostname's super() no-ops - no plain `hostname N` call)
#   use=openrc: /etc/conf.d/hostname's hostname="..." line replaced in
#    place; a file without a hostname= line crashes real Ansible with a
#    TypeError (its reader returns None); a MISSING file reads as "" and
#    the write produces a lone "\n" (both live-verified)
#
# The systemd/debian strategy paths talk to the host only through
# #remote_exec, so those examples run the REAL plugin binary against
# shim binaries (a fake hostnamectl first on PATH via the plugin's
# `_environment` seam) and assert on the argument lines the shim logs.
# The redhat/openrc/alpine strategies do real Crystal File I/O on
# hardcoded system paths (/etc/sysconfig/network, /etc/conf.d/hostname,
# /etc/hostname), which non-root specs must not touch: the file-mutation
# paths were live-verified in the container against BOTH real Ansible
# and the rebuilt krikri plugin binary (see the specs below that only
# assert the readable paths), and the examples here guard on machine
# state like the service param-coverage spec does.

private def with_hostname_shims(static : String, transient : String, &)
  dir = File.join(Dir.tempdir, "krikri-hostname-param-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)

  File.write(File.join(dir, "hostnamectl"), <<-'SH')
    #!/bin/sh
    echo "hostnamectl $*" >> "$KRIKRI_HOSTNAME_LOG"
    case "$*" in
      "--transient status") printf '%s\n' "$KRIKRI_HOSTNAME_TRANSIENT" ;;
      "--static status")    printf '%s\n' "$KRIKRI_HOSTNAME_STATIC" ;;
      *) exit 0 ;;
    esac
  SH
  File.chmod(File.join(dir, "hostnamectl"), 0o755)

  env = {
    "PATH"                      => "#{dir}:/usr/bin:/bin",
    "KRIKRI_HOSTNAME_LOG"       => log,
    "KRIKRI_HOSTNAME_STATIC"    => static,
    "KRIKRI_HOSTNAME_TRANSIENT" => transient,
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

# PATH pointing at an EMPTY dir only: no hostnamectl anywhere, to
# exercise the explicit-use get_bin_path failure (the auto-detect path
# would fall back instead of failing).
private def with_no_binaries(&)
  dir = File.join(Dir.tempdir, "krikri-hostname-empty-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  yield({"PATH" => dir, "KRIKRI_HOSTNAME_LOG" => log}.to_json, log)
ensure
  FileUtils.rm_rf(dir) if dir
end

# A shim for the hostname(1) binary itself (alpine's `hostname -F ...`),
# alongside a hostnamectl shim.
private def with_hostname_cmd_shim(&)
  dir = File.join(Dir.tempdir, "krikri-hostname-cmd-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "hostname"), <<-'SH')
    #!/bin/sh
    echo "hostname $*" >> "$KRIKRI_HOSTNAME_LOG"
    exit 0
  SH
  File.chmod(File.join(dir, "hostname"), 0o755)
  yield({"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_HOSTNAME_LOG" => log}.to_json, log)
ensure
  FileUtils.rm_rf(dir) if dir
end

private def read_calls(log : String) : Array(String)
  File.exists?(log) ? File.read_lines(log) : [] of String
end

private def expect_ok(result : JSON::Any) : Nil
  return unless result["failed"]?.try(&.as_bool)
  raise "task failed: #{result["msg"]?}"
end

describe "hostname plugin - use: parameter coverage" do
  describe "argument validation" do
    it "fails with real Ansible's exact choice-validation message (live-verified text)" do
      with_hostname_shims("x", "x") do |env, log|
        result = PluginSpecHelper.run("hostname", {
          "name" => "web01", "use" => "bogus", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("value of use must be one of: alpine, debian, freebsd, generic, macos, macosx, darwin, openbsd, openrc, redhat, sles, solaris, systemd, got: bogus")
        read_calls(log).should eq([] of String)
      end
    end

    it "checks required name before choice validation (live-verified order)" do
      result = PluginSpecHelper.run("hostname", {"use" => "bogus"})
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("missing required arguments: name")
    end

    it "fails on use: generic - real Ansible's Base strategy is a NotImplementedError crash (live-verified)" do
      with_hostname_shims("x", "x") do |env, log|
        result = PluginSpecHelper.run("hostname", {
          "name" => "web01", "use" => "generic", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should contain("NotImplementedError")
        read_calls(log).should eq([] of String)
      end
    end

    it "rejects non-Linux strategies explicitly (Linux-only engine)" do
      result = PluginSpecHelper.run("hostname", {"name" => "web01", "use" => "freebsd"})
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("non-Linux platform strategy")
    end
  end

  describe "use: systemd / use: debian" do
    it "reads transient then static, sets permanent first then transient (live-verified order)" do
      with_hostname_shims("oldstatic", "oldtrans") do |env, log|
        result = PluginSpecHelper.run("hostname", {
          "name" => "newhost", "use" => "systemd", "_environment" => env,
        })
        expect_ok(result)
        result["changed"].as_bool.should be_true
        read_calls(log).should eq([
          "hostnamectl --transient status",
          "hostnamectl --static status",
          "hostnamectl --pretty --static set-hostname newhost",
          "hostnamectl --transient set-hostname newhost",
        ])
      end
    end

    it "is idempotent off the hostnamectl reads alone, and use: debian behaves identically" do
      with_hostname_shims("newhost", "newhost") do |env, log|
        result = PluginSpecHelper.run("hostname", {
          "name" => "newhost", "use" => "debian", "_environment" => env,
        })
        expect_ok(result)
        result["changed"].as_bool.should be_false
        read_calls(log).should eq([
          "hostnamectl --transient status",
          "hostnamectl --static status",
        ])
      end
    end

    it "reports would-change in check mode without any set-hostname call" do
      with_hostname_shims("oldstatic", "oldtrans") do |env, log|
        result = PluginSpecHelper.run("hostname", {
          "name" => "newhost", "use" => "systemd", "check_mode" => "true", "_environment" => env,
        })
        expect_ok(result)
        result["changed"].as_bool.should be_true
        read_calls(log).none?(&.includes?("set-hostname")).should be_true
      end
    end

    it "fails with real Ansible's >64-char message on the actual set only (live-verified text and check-mode behavior)" do
      long_name = "a" * 65
      with_hostname_shims("oldstatic", "oldtrans") do |env, log|
        result = PluginSpecHelper.run("hostname", {
          "name" => long_name, "use" => "systemd", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("name cannot be longer than 64 characters on systemd servers, try a shorter name")
        read_calls(log).none?(&.includes?("set-hostname")).should be_true
      end

      with_hostname_shims("oldstatic", "oldtrans") do |env, _log|
        result = PluginSpecHelper.run("hostname", {
          "name" => long_name, "use" => "systemd", "check_mode" => "true", "_environment" => env,
        })
        expect_ok(result)
        result["changed"].as_bool.should be_true
      end
    end

    it "fails with real Ansible's get_bin_path message when hostnamectl is absent (live-verified text)" do
      with_no_binaries do |env, _log|
        result = PluginSpecHelper.run("hostname", {
          "name" => "newhost", "use" => "systemd", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should contain("Failed to find required executable \"hostnamectl\" in paths:")
      end
    end

    it "surfaces a failing hostnamectl as real Ansible's Command failed message (live-verified text)" do
      dir = File.join(Dir.tempdir, "krikri-hostname-fail-#{Random.rand(1_000_000)}")
      log = File.join(dir, "calls.log")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "hostnamectl"), <<-'SH')
        #!/bin/sh
        echo "hostnamectl $*" >> "$KRIKRI_HOSTNAME_LOG"
        case "$*" in
          *status) echo "bus failure" >&2; exit 1 ;;
        esac
      SH
      File.chmod(File.join(dir, "hostnamectl"), 0o755)
      env = {"PATH" => "#{dir}:/usr/bin:/bin", "KRIKRI_HOSTNAME_LOG" => log}.to_json
      result = PluginSpecHelper.run("hostname", {
        "name" => "newhost", "use" => "systemd", "_environment" => env,
      })
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("Command failed rc=1, out=, err=bus failure\n")
    end
  end

  describe "use: alpine" do
    it "is idempotent off /etc/hostname content alone (no commands)" do
      hostname_file = "/etc/hostname"
      pending!("real /etc/hostname not readable") unless File.readable?(hostname_file)
      current = File.read(hostname_file).strip
      with_hostname_shims("", "") do |env, log|
        result = PluginSpecHelper.run("hostname", {
          "name" => current, "use" => "alpine", "_environment" => env,
        })
        expect_ok(result)
        result["changed"].as_bool.should be_false
        read_calls(log).should eq([] of String)
      end
    end

    it "runs `hostname -F /etc/hostname` BEFORE the file write, and never a plain `hostname <name>` (live-verified order)" do
      # The file write targets the real /etc/hostname, which this spec
      # must not touch: when the write fails (non-root), real Ansible
      # fails the same way with the same message, so we assert the
      # command order plus that failure; skipped when running as root
      # (where the plugin - and real Ansible - would legitimately
      # rewrite the file).
      pending!("would touch the real /etc/hostname") if File.writable?("/etc/hostname")
      with_hostname_cmd_shim do |env, log|
        result = PluginSpecHelper.run("hostname", {
          "name" => "krikri-spec-unreachable", "use" => "alpine", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should start_with("failed to update hostname:")
        calls = read_calls(log)
        calls.size.should eq(1)
        calls[0].should eq("hostname -F /etc/hostname")
      end
    end
  end

  describe "use: redhat" do
    it "fails with real Ansible's exact message when /etc/sysconfig/network has no HOSTNAME entry (live-verified text, check mode included)" do
      pending!("/etc/sysconfig/network exists on this machine; the no-entry failure needs to control the file") if File.exists?("/etc/sysconfig/network")
      result = PluginSpecHelper.run("hostname", {
        "name" => "web01", "use" => "redhat", "check_mode" => "true",
      })
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("Unable to locate HOSTNAME entry in /etc/sysconfig/network")
    end
  end

  describe "use: openrc" do
    it "reads a missing /etc/conf.d/hostname as \"\" and reports would-change in check mode (live-verified semantics)" do
      pending!("/etc/conf.d/hostname exists on this machine") if File.exists?("/etc/conf.d/hostname")
      result = PluginSpecHelper.run("hostname", {
        "name" => "newhost", "use" => "openrc", "check_mode" => "true",
      })
      expect_ok(result)
      result["changed"].as_bool.should be_true
    end

    it "fails with real Ansible's 'failed to update hostname: [Errno ...]' text when /etc/conf.d is missing (live-verified in a container)" do
      pending!("/etc/conf.d exists on this machine; the write failure needs to control the file") if File.exists?("/etc/conf.d")
      result = PluginSpecHelper.run("hostname", {"name" => "newhost", "use" => "openrc"})
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("failed to update hostname: [Errno 2] No such file or directory: '/etc/conf.d/hostname'")
    end
  end

  describe "use: alpine write failure" do
    it "fails with real Ansible's 'failed to update hostname: [Errno ...]' text when the file write fails (live-verified in a container)" do
      # Same guard as the command-order example: only run when the real
      # /etc/hostname write would fail at the OS level (non-root), so
      # nothing is ever written. As non-root the write fails with EACCES,
      # rendered here as Python's str(OSError), matching real Ansible's
      # "failed to update hostname: %s" % to_native(e) shape (Errno 2
      # variant container-verified side by side).
      pending!("would touch the real /etc/hostname") if File.writable?("/etc/hostname")
      with_hostname_cmd_shim do |env, _log|
        result = PluginSpecHelper.run("hostname", {
          "name" => "krikri-spec-unreachable", "use" => "alpine", "_environment" => env,
        })
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("failed to update hostname: [Errno 13] Permission denied: '/etc/hostname'")
      end
    end
  end
end
