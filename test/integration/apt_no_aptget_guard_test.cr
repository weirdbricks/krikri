require "../minitest_helper"
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
end
