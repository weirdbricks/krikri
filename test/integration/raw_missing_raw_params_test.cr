require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, extra_args : Array(String) = [] of String)
  playbook = File.tempname("raw-missing-raw-params", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook] + extra_args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# raw:'s action plugin reads ONLY `_raw_params` (ansible/plugins/action/
# raw.py hands `self._task.args.get('_raw_params')` straight into
# _low_level_execute_command): `free_form:`/`cmd:`/`argv:` are params it
# never consults, and raw has no module side to reject them either, so a
# mapping-form raw without `_raw_params` crashes INSIDE the action with
# Python's "'NoneType' object is not iterable" - the task executor wraps
# it as "Task failed: <exception>" and failed_when: never applies (the
# exception escapes before the changed_when/failed_when pass). krikri
# aliases raw: onto the shell plugin, whose required_one_of accepted
# cmd:/argv: and worded the empty case "one of the following is
# required: _raw_params, cmd, argv" - all live-verified against
# ansible-playbook 2.19.11 (issue #765). In check mode real's action
# plugin returns the bare skip shape BEFORE reading any args.
describe "raw: without _raw_params" do
  it "free_form mapping fails with real's NoneType crash wording, not the shell required_one_of one" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: raw free_form
            ansible.builtin.raw:
              free_form: echo hi
            register: r
            ignore_errors: true
          - name: show registered shape
            ansible.builtin.debug:
              msg: "failed={{ r.failed }} changed={{ r.changed }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: 'NoneType' object is not iterable\"}")
    output.must_include("[ERROR]: Task failed: 'NoneType' object is not iterable")
    output.must_include("...ignoring")
    output.must_include("ignored=1")
    output.must_include("failed=True changed=False")
    output.wont_include("one of the following is required")
  end

  it "cmd mapping fails the same way - real's raw action ignores cmd entirely" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: raw cmd mapping
            ansible.builtin.raw:
              cmd: echo hi
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("Task failed: 'NoneType' object is not iterable")
    output.wont_include("echo hi")
  end

  it "bare-string raw still runs - its command IS real's _raw_params" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: bare raw
            ansible.builtin.raw: echo still-runs
            register: r
          - name: show registered shape
            ansible.builtin.debug:
              msg: "changed={{ r.changed }} rc={{ r.rc }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("changed=True rc=0")
    output.wont_include("NoneType")
  end

  it "check mode skips the task instead of failing it - real's action skips before reading args" do
    status, output = run_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: raw free_form
            ansible.builtin.raw:
              free_form: echo hi
            register: r
            ignore_errors: true
          - name: show registered shape
            ansible.builtin.debug:
              msg: "skipped={{ r.skipped | default('none') }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("skipping: [localhost]")
    output.must_include("skipped=1")
    output.must_include("skipped=True")
    output.wont_include("NoneType")
  end

  it "failed_when: false does not rescue the crash - the exception escapes before the failed_when pass" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: raw free_form
            ansible.builtin.raw:
              free_form: echo hi
            failed_when: false
      YAML

    # Real ansible-playbook exits 2 on the unrescued failure too
    status.exit_code.must_equal(2)
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: 'NoneType' object is not iterable\"}")
    output.must_include("failed=1")
    output.wont_include("...ignoring")
  end
end
