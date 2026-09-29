require "../minitest_helper"
require "file_utils"

# Live-compared byte for byte with real ansible-playbook 2.19.11 (via
# scripts/output_parity.sh on the same playbooks): debug: msg keeps native
# YAML/Jinja types, an undefined `var:` prints the inline error marker plus a
# stderr template-error warning, and a failing include_vars uses the standard
# failure display (action-level block, real's result keys).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_krikri(playbook_text : String) : {String, String}
  playbook = File.tempname("debug-native", ".yml")
  File.write(playbook, playbook_text)
  captured_out = IO::Memory.new
  captured_err = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured_out, error: captured_err)
  {captured_out.to_s.gsub(playbook, "PB"), captured_err.to_s.gsub(playbook, "PB")}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "debug native typing and include_vars failures" do
  it "keeps literal and whole-span scalar types in debug msg" do
    stdout_text, _ = run_krikri(<<-YAML)
      - hosts: localhost
        gather_facts: false
        vars: {pv: 1, pf: 1.5, pb: true, ps: str}
        tasks:
          - {ansible.builtin.debug: {msg: 1}}
          - {ansible.builtin.debug: {msg: true}}
          - {ansible.builtin.debug: {msg: "1"}}
          - {ansible.builtin.debug: {msg: "{{ pv }}"}}
          - {ansible.builtin.debug: {msg: "{{ pb }}"}}
          - {ansible.builtin.debug: {msg: "{{ pv == 1 }}"}}
          - {ansible.builtin.debug: {msg: "n={{ pv }}"}}
          - {ansible.builtin.debug: {msg: "{{ pv | string }}"}}
      YAML
    msgs = stdout_text.lines.select(&.includes?(%("msg":))).map(&.strip)
    msgs.must_equal([%("msg": 1), %("msg": true), %("msg": "1"), %("msg": 1), %("msg": true), %("msg": true), %("msg": "n=1"), %("msg": "1")])
  end

  it "prints the inline error marker and the stderr template-error warning for an undefined var:" do
    stdout_text, stderr_text = run_krikri(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              var: nope_zzz
      YAML
    stdout_text.must_include(%("nope_zzz": "<< error 1 - 'nope_zzz' is undefined >>"))
    stderr_text.must_include("[WARNING]: Encountered 1 template error.\nerror 1 - 'nope_zzz' is undefined\nOrigin: PB:5:14")
  end

  it "fails include_vars with real's result keys and action-level block" do
    stdout_text, _ = run_krikri(<<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.include_vars:
              file: /nonexistent/krikri_spec_vars.yml
            ignore_errors: true
      YAML
    stdout_text.must_include("TASK [ansible.builtin.include_vars]")
    stdout_text.must_include("[ERROR]: Task failed: Action failed: Unknown error.")
    stdout_text.must_include(%(fatal: [localhost]: FAILED! => {"ansible_facts": {}, "ansible_included_var_files": [], "changed": false, "message": "Could not find or access '/nonexistent/krikri_spec_vars.yml' on the Ansible Controller.\\nIf you are using a module and expect the file to exist on the remote, see the remote_src option", "msg": "Task failed: Action failed: Unknown error."}))
    stdout_text.must_include("...ignoring")
  end
end
