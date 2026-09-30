require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# Regression tests for the CLI-mode output-parity work on real Ansible's
# ModuleArgsParser refusals (live-verified vs 2.19.11): a SECOND
# non-keyword key beside the chosen action is a whole-playbook abort -
# "conflicting action statements: <first>, <second>" named in task-key
# order, rc=4, with the task's Origin block - and a non-string,
# non-mapping value on the chosen action is mod_args' "unexpected
# parameter type in action: <class 'bool'>", checked BEFORE any later
# key's conflict can fire.
describe "conflicting action statement detection" do
  it "raises the conflict for an unknown key after the action" do
    content = "---\n- name: p\n  hosts: web1\n  tasks:\n    - name: bad task\n      ansible.builtin.debug:\n        msg: hi\n      any_bogus_keyword: yes\n"
    ex = assert_raises(Krikri::ConflictingActionStatementsError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.must_equal("conflicting action statements: ansible.builtin.debug, any_bogus_keyword")
    # The Origin block only renders when the playbook exists on disk
    # (parse_string's in-memory default path doesn't), so assert the
    # [ERROR] line; the full Origin block is covered live by
    # scripts/cli_output_parity.sh's syntax-check-kw-err case.
    ex.render.as(String).lines.first.must_equal("[ERROR]: conflicting action statements: ansible.builtin.debug, any_bogus_keyword")
  end

  it "raises the conflict for a dict-valued unknown key after the action" do
    content = "---\n- name: p\n  hosts: web1\n  tasks:\n    - name: d1\n      ansible.builtin.debug:\n        msg: hi\n      foo_bar:\n        a: b\n"
    ex = assert_raises(Krikri::ConflictingActionStatementsError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.must_equal("conflicting action statements: ansible.builtin.debug, foo_bar")
  end

  it "type-checks a bool-valued first action before any later conflict" do
    content = "---\n- name: p\n  hosts: web1\n  tasks:\n    - name: d1\n      any_bogus_keyword: yes\n      ansible.builtin.debug:\n        msg: hi\n"
    ex = assert_raises(Krikri::MetaActionTypeError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.must_equal("unexpected parameter type in action: <class 'bool'>")
  end

  it "keeps parsing a plain multi-key task without conflict" do
    content = "---\n- name: p\n  hosts: web1\n  tasks:\n    - name: ok task\n      ansible.builtin.debug:\n        msg: hi\n      when: true\n      tags: [a]\n"
    play = Krikri::PlaybookParser.parse_string(content).plays[0]
    play.tasks[0].module_name.must_equal("ansible.builtin.debug")
  end
end
