require "../minitest_helper"

# A changed_when:/failed_whose evaluation that RAISES must not overwrite
# the module result's own msg: task_executor.py's `except AnsibleError`
# tail sets failed=True and records the error text (with Ansible's own
# "Error while evaluating conditional: " prefix) in
# changed_when_result/failed_when_result, leaving msg alone. krikri used
# to replace msg with the evaluation error, so an argspec-violation
# result (stat's removed get_md5) with a broken changed_when: reported
# "object of type 'dict' has no attribute 'stat'" as its msg where real
# kept "Unsupported parameters for (...) module: ..." (found on round
# 5220000's bodsch.icingaweb2 confirm, where the role's stat tasks carry
# get_md5 and a register-referencing changed_when:).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("changed-when-error-shape", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "changed_when:/failed_when: evaluation errors keep the module's own msg" do
  it "records the evaluation error in changed_when_result on an already-failed result" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: stat with removed get_md5 and a broken changed_when
            ansible.builtin.stat:
              path: /etc/hostname
              get_md5: false
            register: stat_result
            changed_when: not stat_result.stat.exists
            ignore_errors: true
      YAML

    output.must_include(%("msg": "Unsupported parameters for (ansible.builtin.stat) module: get_md5.))
    output.must_include(%("changed_when_result": "Error while evaluating conditional: object of type 'dict' has no attribute 'stat'"))
  end

  it "keeps the module msg on an ok result with a raising changed_when/failed_when" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: ok result, raising changed_when
            ansible.builtin.debug:
              msg: hello
            changed_when: broken_var.missingattr
            ignore_errors: true
          - name: ok result, raising failed_when
            ansible.builtin.debug:
              msg: hello
            failed_when: broken_var2.missingattr
            ignore_errors: true
      YAML

    # Both fatal results keep the debug msg; the evaluation error only
    # surfaces in the *_when_result field and the ERROR banner.
    output.must_include(%("msg": "hello"))
    output.wont_include(%("msg": "'broken_var' is undefined"))
    output.wont_include(%("msg": "'broken_var2' is undefined"))
    # The ERROR banner is normalized from the module msg, not from the
    # evaluation error - matching real's "Task failed: Action failed:
    # hello" exactly. (The *_when_result field itself rides the
    # registered result but the console fatal block doesn't display it,
    # on either engine.)
  end
end
