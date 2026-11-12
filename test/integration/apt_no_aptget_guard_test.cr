require "../minitest_helper"
require "../../src/krikri/plugin_helpers/apt_lock_retry"
require "file_utils"

# Issue #18 (round 196 Oefenweb.dns on Rocky 9.6; azavea.duply,
# calvinbui.ansible_nut, capitanh.harbork8s_ansible_role,
# dottgonzo.upgrade_system_and_reboot, tobias_richter.apt_packages on
# Ubuntu): on a host with no apt-get, real apt.py's python3-apt
# auto-install prefetch (`apt-get update` through
# AnsibleModule.run_command) fails ENOENT, and the module
# - warns "Updating cache and auto-installing missing dependency:
#   python3-apt" BEFORE failing,
# - fail_json's {changed, cmd: update, msg: "Error executing
#   command.", rc: 2, stderr: "", stderr_lines: [], stdout: "",
#   stdout_lines: []} - empty stdout/stderr(+_lines), no cache keys,
#   keys dumped sorted (live-verified vs 2.19.11), and
# - renders the [ERROR] block with the Errno text from the run_command
#   exception: "Task failed: Module failed: Error executing command:
#   [Errno 2] No such file or directory: b'update'".
# krikri's guard used to return a bare {changed, cmd, msg, rc} fatal
# with a backfilled `cache_updated: false` and no warning. The guard
# probes fixed /usr paths, so the shape is only provable on a host
# without apt-get: run the full engine inside the throwaway fedora
# container (same pattern as key_order_round994003_test.cr's firewalld
# specs; fedora ships no apt-get).

private PROJECT_ROOT  = File.expand_path("../..", __DIR__)
private BINARY        = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private COMPAT_IMAGE  = "localhost/krikri-fedora-compat:latest"
private GUARD_WARNING = "[WARNING]: Updating cache and auto-installing missing dependency: python3-apt"
private GUARD_ERROR   = "[ERROR]: Task failed: Module failed: Error executing command: [Errno 2] No such file or directory: b'update'"
private GUARD_FATAL   = %({"changed": false, "cmd": "update", "msg": "Error executing command.", "rc": 2, "stderr": "", "stderr_lines": [], "stdout": "", "stdout_lines": []})

describe "apt: no-apt-get guard shape" do
  # Issue #1035 (akoeb.common, round29903254): what `--check` must report
  # for the role's own "Run apt dist upgrade" shape (`apt: upgrade=dist
  # update_cache=yes`) on an apt-less host. Real apt.py's
  # !HAVE_PYTHON_APT ladder fails check mode with the bare python3-apt
  # refusal BEFORE the auto-install attempt the guard below mirrors, so
  # none of that shape's cmd/rc keys, no warning and no cache keys appear
  # (ansible's fail_json here is exactly {changed, msg}). `_apt_get_paths`
  # forces the no-apt-get probe absent on a dev box that really has
  # apt-get, and the PYTHONPATH stub makes the bindings probe (the
  # absolute /usr/bin/python3, unshimable via PATH) fail the way a host
  # without python3-apt does.
  it "refuses akoeb.common's apt dist upgrade --check run with the python3-apt message (issue #1035)" do
    stub_dir = PluginSpecHelper.tmp_path("no-python3-apt-stub-1035")
    Dir.mkdir_p(stub_dir)
    File.write(File.join(stub_dir, "apt.py"), %(raise ImportError("No module named 'apt'")\n))

    result = PluginSpecHelper.run("apt", {
      "upgrade"             => "dist",
      "update_cache"        => "yes",
      "_ansible_check_mode" => "true",
      "_apt_get_paths"      => "/nonexistent-krikri-spec/apt-get,/nonexistent-krikri-spec/apt-get-local",
    }, env: {"PYTHONPATH" => stub_dir})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("python3-apt must be installed to use check mode. If run normally this module can auto-install it, see the auto_install_module_deps option.")
    result["cmd"]?.must_be_nil
    result["rc"]?.must_be_nil
    result["warnings"]?.must_be_nil
    result["cache_updated"]?.must_be_nil
  end

  it "matches ansible's run_command ENOENT failure (warning, error block, fatal JSON)" do
    unless PluginSpecHelper.container_cli_available?
      skip("podman unavailable")
    end
    output = IO::Memory.new
    Process.run("podman", ["image", "exists", COMPAT_IMAGE], output: output, error: output)
    skip("#{COMPAT_IMAGE} unavailable") unless $?.success?

    work = PluginSpecHelper.tmp_path("apt-noaptget-work")
    FileUtils.rm_rf(work)
    FileUtils.mkdir_p(work)
    File.write(File.join(work, "play.yml"), <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: apt on an apt-less host
            ansible.builtin.apt:
              name: bash
              state: present
      YAML

    run_output = IO::Memory.new
    Process.run("podman", [
      "run", "--rm", "--name", "krikri-apt-noaptget-#{Process.pid}",
      "-v", "#{File.dirname(BINARY)}:/kbin:ro",
      "-v", "#{work}:/work",
      COMPAT_IMAGE,
      "sh", "-c", "/kbin/krikri-playbook -i localhost, -c local /work/play.yml",
    ], output: run_output, error: run_output)
    out = run_output.to_s

    out.must_include(GUARD_WARNING)
    out.must_include(GUARD_ERROR)
    out.must_include("fatal: [localhost]: FAILED! => #{GUARD_FATAL}")
    # the old shape backfilled cache_updated on this exit; real fail_json
    # carries no cache keys
    out.wont_include("cache_updated")
  end

  # Issue #1034 (ajilraju.apache2 on Rocky, round 29903266, check
  # phase): apt.py's !HAVE_PYTHON_APT ladder refuses in check mode
  # BEFORE it ever attempts the python3-apt auto-install, so a
  # check-mode task on an apt-less host fails with the bare
  # {"changed": false, "msg": <refusal>} - no cmd/rc keys and no
  # auto-install warning - where this engine returned the guard's
  # ENOENT auto-install shape (the guard used to be evaluated before
  # the refusal). The `_apt_get_paths`/`_python_apt_absent` seams force
  # both host-state conditions (no apt-get, no python3-apt) on a dev
  # box that really has them, so the ladder ORDER is provable without
  # a container.
  it "refuses in check mode before the no-apt-get guard (issue #1034)" do
    result = PluginSpecHelper.run("apt", {
      "name"                => "apache2",
      "state"               => "present",
      "update_cache"        => "true",
      "_apt_get_paths"      => "/nonexistent-krikri-spec/apt-get,/nonexistent-krikri-spec/apt-get-local",
      "_python_apt_absent"  => "true",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(Krikri::AptLockRetry::CHECK_MODE_NO_PYTHON_APT_MSG)
    # real's ladder fail_json carries ONLY changed+msg: no cmd/rc from
    # the ENOENT auto-install shape, no cache keys, no warning
    result["cmd"]?.must_be_nil
    result["rc"]?.must_be_nil
    result["cache_updated"]?.must_be_nil
    result["warnings"]?.must_be_nil
  end

  it "keeps the run_command ENOENT auto-install shape outside check mode" do
    result = PluginSpecHelper.run("apt", {
      "name"               => "apache2",
      "state"              => "present",
      "update_cache"       => "true",
      "_apt_get_paths"     => "/nonexistent-krikri-spec/apt-get,/nonexistent-krikri-spec/apt-get-local",
      "_python_apt_absent" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["cmd"].as_s.must_equal("update")
    result["rc"].as_i.must_equal(2)
    result["warnings"].as_a.map(&.as_s).must_equal(
      ["Updating cache and auto-installing missing dependency: python3-apt"])
    result["cache_updated"]?.must_be_nil
  end

  # Issue #1172 (timstaley.base on Rocky, round29908315): with
  # update_cache=no apt.py's !HAVE_PYTHON_APT ladder SKIPS the `apt-get
  # update` prefetch - the warning is the other variant ("Auto-installing
  # missing dependency without updating cache") and the install attempt's
  # None binary is silently dropped by run_command (`if x is not None` in
  # basic.py), so coreutils' `install` becomes argv[0] and executes via
  # PATH, dying on the unknown -y flag (rc 1, real stderr) instead of the
  # prefetch's apt-get ENOENT (rc 2, empty stderr). The install runs for
  # real here - the dev box's coreutils, exactly like Rocky's - and is
  # deterministic (invalid option aborts before any operand work), so no
  # host mutation.
  it "matches ansible's update_cache=no auto-install failure shape (issue #1172)" do
    result = PluginSpecHelper.run("apt", {
      "name"           => "aptitude",
      "state"          => "present",
      "update_cache"   => "false",
      "_apt_get_paths" => "/nonexistent-krikri-spec/apt-get,/nonexistent-krikri-spec/apt-get-local",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("install: invalid option -- 'y'\nTry 'install --help' for more information.")
    result["cmd"].as_s.must_equal(%(install python3-apt -y -q '-o "Dpkg::Options::=--force-confdef" -o "Dpkg::Options::=--force-confold" -o DPkg::Lock::Timeout=60'))
    result["rc"].as_i.must_equal(1)
    result["stderr"].as_s.must_equal("install: invalid option -- 'y'\nTry 'install --help' for more information.\n")
    result["stderr_lines"].as_a.map(&.as_s).must_equal([
      "install: invalid option -- 'y'",
      "Try 'install --help' for more information.",
    ])
    result["stdout"].as_s.must_equal("")
    result["stdout_lines"].as_a.map(&.as_s).must_equal([] of String)
    result["warnings"].as_a.map(&.as_s).must_equal(
      ["Auto-installing missing dependency without updating cache: python3-apt"])
    result["cache_updated"]?.must_be_nil
  end

  # The same branch's OSError sibling (issue #1172's code path): a host
  # whose PATH holds no `install` binary either (busybox-only images)
  # fails at execvp, so run_command's OSError handler shapes the result
  # (the prefetch-ENOENT shape with b'install' as the failed exec name)
  # instead of the check_rc stderr shape the install run produces on
  # coreutils hosts. The PATH stub makes both the probe and the would-be
  # exec see no install; nothing runs, so no host mutation.
  it "falls back to the run_command OSError shape when no install binary exists (issue #1172)" do
    stub_dir = PluginSpecHelper.tmp_path("no-install-stub-1172")
    Dir.mkdir_p(stub_dir)

    result = PluginSpecHelper.run("apt", {
      "name"           => "aptitude",
      "state"          => "present",
      "update_cache"   => "false",
      "_apt_get_paths" => "/nonexistent-krikri-spec/apt-get,/nonexistent-krikri-spec/apt-get-local",
    }, env: {"PATH" => stub_dir})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["cmd"].as_s.must_equal(%(install python3-apt -y -q '-o "Dpkg::Options::=--force-confdef" -o "Dpkg::Options::=--force-confold" -o DPkg::Lock::Timeout=60'))
    result["rc"].as_i.must_equal(2)
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.must_equal("")
    result["_ansible_error_detail"].as_s.must_equal("Error executing command: [Errno 2] No such file or directory: b'install'")
    result["warnings"].as_a.map(&.as_s).must_equal(
      ["Auto-installing missing dependency without updating cache: python3-apt"])
    result["cache_updated"]?.must_be_nil
  end

  it "matches ansible's check-mode refusal in the container (bare msg, no warning)" do
    unless PluginSpecHelper.container_cli_available?
      skip("podman unavailable")
    end
    output = IO::Memory.new
    Process.run("podman", ["image", "exists", COMPAT_IMAGE], output: output, error: output)
    skip("#{COMPAT_IMAGE} unavailable") unless $?.success?

    work = PluginSpecHelper.tmp_path("apt-noaptget-check-work")
    FileUtils.rm_rf(work)
    FileUtils.mkdir_p(work)
    File.write(File.join(work, "play.yml"), <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: apt on an apt-less host in check mode
            ansible.builtin.apt:
              name: bash
              state: present
      YAML

    run_output = IO::Memory.new
    Process.run("podman", [
      "run", "--rm", "--name", "krikri-apt-noaptget-check-#{Process.pid}",
      "-v", "#{File.dirname(BINARY)}:/kbin:ro",
      "-v", "#{work}:/work",
      COMPAT_IMAGE,
      "sh", "-c", "/kbin/krikri-playbook -i localhost, -c local --check /work/play.yml",
    ], output: run_output, error: run_output)
    out = run_output.to_s

    out.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"#{Krikri::AptLockRetry::CHECK_MODE_NO_PYTHON_APT_MSG}\"}")
    out.wont_include(GUARD_WARNING)
    out.wont_include("Error executing command")
    out.wont_include("cache_updated")
  end
end

# Regression spec for issue #1033 (agx.gbp on Rocky 9.6, round29903240,
# --check phase): real apt.py's !HAVE_PYTHON_APT ladder fails CHECK mode
# with the python3-apt message BEFORE ever attempting the auto-install
# (it is a real host mutation), so the run_command ENOENT shape above is
# a NORMAL-run-only outcome. The guard here used to answer a --check run
# with that shape - "Error executing command." plus the auto-install
# warning - where ansible's --check output was the bare python3-apt
# refusal. `_apt_get_paths` (same seam family as apt_repository's) forces
# the gate on a dev box that really has apt-get, and the python3-apt
# probe (absolute /usr/bin/python3, unshimable via PATH) is pointed at a
# stub `apt` module that raises on import via the child-only PYTHONPATH.
describe "apt: no-apt-get guard check-mode refusal (issue #1033)" do
  it "reports the python3-apt check-mode refusal, never the auto-install ENOENT shape" do
    stub_dir = PluginSpecHelper.tmp_path("no-python3-apt-stub")
    Dir.mkdir_p(stub_dir)
    File.write(File.join(stub_dir, "apt.py"), %(raise ImportError("No module named 'apt'")\n))

    result = PluginSpecHelper.run("apt", {
      "name"                => "cowbuilder",
      "state"               => "latest",
      "_apt_get_paths"      => "/nonexistent-krikri-spec/apt-get,/nonexistent-krikri-spec/apt-get-local",
      "_ansible_check_mode" => "true",
    }, env: {"PYTHONPATH" => stub_dir})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("python3-apt must be installed to use check mode. If run normally this module can auto-install it, see the auto_install_module_deps option.")
    # real's check-mode refusal is a bare fail_json: no cmd/rc from an
    # auto-install that never runs under --check, no cache keys, no
    # warning - exactly the four keys ansible's loop-item line dumps
    # ({ansible_loop_var, changed, item, msg}).
    result["cmd"]?.must_be_nil
    result["rc"]?.must_be_nil
    result["cache_updated"]?.must_be_nil
    result["warnings"]?.must_be_nil
  end

  it "keeps the run_command ENOENT shape for a normal run" do
    result = PluginSpecHelper.run("apt", {
      "name"           => "cowbuilder",
      "state"          => "latest",
      "_apt_get_paths" => "/nonexistent-krikri-spec/apt-get,/nonexistent-krikri-spec/apt-get-local",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["cmd"].as_s.must_equal("update")
    result["rc"].as_i.must_equal(2)
    result["warnings"].as_a.map(&.as_s).must_equal(["Updating cache and auto-installing missing dependency: python3-apt"])
  end

  it "reports the refusal in the engine console output under --check" do
    unless PluginSpecHelper.container_cli_available?
      skip("podman unavailable")
    end
    output = IO::Memory.new
    Process.run("podman", ["image", "exists", COMPAT_IMAGE], output: output, error: output)
    skip("#{COMPAT_IMAGE} unavailable") unless $?.success?

    work = PluginSpecHelper.tmp_path("apt-noaptget-check-work")
    FileUtils.rm_rf(work)
    FileUtils.mkdir_p(work)
    File.write(File.join(work, "play.yml"), <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: apt on an apt-less host
            ansible.builtin.apt:
              name: bash
              state: present
      YAML

    run_output = IO::Memory.new
    Process.run("podman", [
      "run", "--rm", "--name", "krikri-apt-noaptget-check-#{Process.pid}",
      "-v", "#{File.dirname(BINARY)}:/kbin:ro",
      "-v", "#{work}:/work",
      COMPAT_IMAGE,
      "sh", "-c", "/kbin/krikri-playbook -i localhost, -c local /work/play.yml --check",
    ], output: run_output, error: run_output)
    out = run_output.to_s

    out.must_include("[ERROR]: Task failed: Module failed: python3-apt must be installed to use check mode. If run normally this module can auto-install it, see the auto_install_module_deps option.")
    out.wont_include(GUARD_WARNING)
    out.wont_include(GUARD_ERROR)
    out.wont_include(GUARD_FATAL)
  end
end
