require "../minitest_helper"

# Issue #814 (deveth0.pct): a legacy free-form `local_action: shell ...`
# directive names its module INLINE, so krikri's free-form detection -
# which looks for a bare `shell:` key line - never fired, and two parity
# gaps followed (live-captured vs ansible-core 2.19.11):
#
# 1. The fatal msg named `cmd` where ansible names `_raw_params`
#    (_normalize_old_style_args stores the string under `_raw_params`
#    exactly like a plain free-form call).
# 2. The whole [ERROR] chain block was missing: ansible prints it with
#    BOTH the middle and the would-be innermost Origin at the module
#    token that opens the directive's value (the directive value is
#    templated as one string to split the module name off), the middle
#    stanza keeps the FULL message (no separate per-key cause level to
#    shorten it to "failed."), and the chain ends there - no third
#    stanza. A plain free-form `command: ...` keeps the shortened
#    middle + innermost two-level shape (command_free_form_
#    finalization_origin_test.cr).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "free-form local_action directive finalization errors" do
  it "reports _raw_params and prints the two-level chain at the module token" do
    src_dir = PluginSpecHelper.tmp_path("local-action-free-form-finalization", "role")
    Dir.mkdir_p(File.join(src_dir, "roles", "pcttest", "tasks"))
    tasks = File.join(src_dir, "roles", "pcttest", "tasks", "main.yml")
    File.write(tasks, <<-YAML)
      ---
      - name: Create VM
        local_action: shell ssh "{{ lxc_hypervisor }}" echo hi
      YAML
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - pcttest
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    # Ansible's failing key is `_raw_params`, never krikri's internal `cmd`.
    text.must_include("Error while resolving value for '_raw_params': 'lxc_hypervisor' is undefined")
    text.wont_include("Error while resolving value for 'cmd'")

    # The chain block: task-level Origin at the `- name:` key (column 3),
    # then the middle stanza with the FULL message and its Origin at the
    # module token that opens the directive value (column 17 = after
    # `  local_action: `).
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.shell' failed: Error while resolving value for '_raw_params': 'lxc_hypervisor' is undefined")
    text.must_include("Origin: #{tasks}:2:3")
    text.must_include("Finalization of task args for 'ansible.builtin.shell' failed: Error while resolving value for '_raw_params': 'lxc_hypervisor' is undefined\nOrigin: #{tasks}:3:17")
    # The chain ends at the middle stanza - ansible prints no third level
    # here, so exactly one `<<< caused by >>>` separator appears.
    text.scan("<<< caused by >>>").size.must_equal(1)
  end
end
