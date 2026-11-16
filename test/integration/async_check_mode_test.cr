require "../minitest_helper"

# Regression for issue #1409 (stancel.restore_bareos_backup's "Restore
# backup": `shell:` + `async: 1800`/`poll: 10`, run under `--check`).
#
# ansible's TaskExecutor does not treat check mode as a reason to skip the
# async path - it gates that path on async_val alone and only forwards
# check_mode onto the synthetic async_status task - so a --check run still
# launches the job, prints "ASYNC OK on <host>: jid=<jid>" before the
# task's own "skipping:" line, and registers the async_status-wrapped
# result whose module half is the module's own check-mode reply. krikri
# skipped the whole job under --check, so no ASYNC OK line appeared and
# the registered result was missing ansible_job_id, started, finished and
# results_file (live-verified vs 2.21.6 for the exact shape this spec
# pins).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# A per-test HOME keeps the job files out of the host-wide
# ~/.ansible_async the async specs and other workers also touch, and lets
# the spec prove results_file points at the controller's own async dir.
private def run_async_check_playbook : {Process::Status, String, String}
  home = PluginSpecHelper.tmp_path("home")
  Dir.mkdir_p(home)
  playbook = PluginSpecHelper.tmp_path("async-check.yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: async job under --check
          ansible.builtin.shell: "/tmp/krikri-async-check-1409.sh"
          async: 30
          poll: 1
          register: command_result
        - name: show the registered result
          ansible.builtin.debug:
            msg: "{{ command_result }}"
    YAML
  output = IO::Memory.new
  status = Process.run(BINARY, ["--check", "-i", INVENTORY, playbook], output: output, error: output, env: {"HOME" => home})
  {status, output.to_s, home}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "async job in a --check run" do
  it "launches the job and registers ansible's async_status shape" do
    status, output, home = run_async_check_playbook

    status.success?.must_equal(true, output)
    # The ASYNC OK line comes BEFORE the task's own check-mode skip line,
    # the order ansible's callback produces.
    output.must_match(/ASYNC OK on localhost: jid=(j\S+)\nskipping: \[localhost\]/)
    output.wont_match(/ASYNC FAILED/)
    jid = output[/ASYNC OK on localhost: jid=(j\S+)/, 1]

    # ansible's async_status base dict survives the check-mode reply: the
    # registered result is not just the module's own skipped result.
    output.must_include(%("ansible_job_id": "#{jid}"))
    output.must_include(%("finished": true))
    output.must_include(%("started": true))
    output.must_include(%("results_file": "#{File.join(home, ".ansible_async", jid)}"))
    # ... around the shell plugin's own check-mode half.
    output.must_include(%("msg": "Command would have run if not in check mode"))
    output.must_include(%("skipped": true))
    output.must_include(%("changed": false))
  end
end
