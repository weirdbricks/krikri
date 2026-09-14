require "file_utils"
require "../spec_helper"

# Real crash found benchmarking cchurch.admin-users (round 811129): its
# "ensure sudo package is installed" task is
# `action: {module: "{{ ansible_pkg_mgr }}", name: ..., state: present}`
# - real Ansible's dynamic-module-dispatch idiom, where the MODULE NAME
# itself is a template only resolvable once ansible_pkg_mgr (a fact) is
# known. PlaybookParser correctly recognizes this at parse time
# (Task#templated_action, resolved later by
# TaskExecutor#resolve_templated_action against real per-host facts) -
# but PluginManager.collect_required_plugins (the pre-run batch-upload
# pass, remote hosts only - a local connection skips it entirely) had no
# exclusion for it, so it added the LITERAL unrendered "{{ ansible_pkg_mgr
# }}" string as a required plugin name. get_local_plugin_path then raised
# an unhandled exception ("Plugin binary not found: {{ ansible_pkg_mgr
# }}"), crashing the whole run before a single task executed - even
# though the real per-host module name (apt/dnf/yum/...) would have
# resolved and uploaded fine once actually rendered.
#
# Uses 127.0.0.1:1 (same technique as unreachable_host_halt_spec.cr) so
# this needs no real remote host at all: the crash happens in the local
# get_local_plugin_path lookup, entirely BEFORE any network connection is
# attempted - only the plugin-name collection itself is under test here.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_repro(playbook : String) : {Int32, String}
  dir = File.tempname("templated-action-upload-repro")
  Dir.mkdir_p(dir)

  File.write(File.join(dir, "inv.ini"),
    "deadhost ansible_host=127.0.0.1 ansible_port=1 ansible_user=root ansible_connection=ssh\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "a task whose module name itself is templated (action: {module: \"{{ ... }}\"})" do
  it "does not crash the pre-run plugin-upload pass with the literal unrendered template text" do
    exit_code, output = run_repro(<<-YAML)
      - hosts: deadhost
        gather_facts: true
        tasks:
          - name: ensure sudo package is installed
            action:
              module: "{{ ansible_pkg_mgr }}"
              name: sudo
              state: present
      YAML

    output.should_not contain("Plugin binary not found: {{ ansible_pkg_mgr }}"), output
    output.should_not contain("Unhandled exception"), output
    # The pre-upload pass now gets past plugin-name collection cleanly;
    # the run still fails at the (genuinely unreachable) SSH connection
    # step right after, same as unreachable_host_halt_spec.cr's own
    # baseline - that failure is expected and irrelevant to this fix.
    exit_code.should eq(4), output
  end
end
