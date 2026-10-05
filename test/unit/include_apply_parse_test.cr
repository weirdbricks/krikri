require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# `apply:` on include_tasks:/include_role: - ansible-core turns that
# mapping into an implicit parent Block for the tasks the include loads
# (task_include.py's build_parent_block), so the parsed include statement
# has to carry its contents to the executor. This engine validated the
# mapping's shape and then threw it away: every keyword in it was
# silently ignored, which is how pandemonium1986.ohmyzsh's
# `apply: {become: true, become_user: "{{ loop_ohmyzsh_users.user_name }}"}`
# ran its included tasks as root (the oh-my-zsh installer wrote
# /root/.zshrc, and lineinfile then failed with "Destination
# /home/pandemonium//.zshrc does not exist !" on a host where
# ansible-playbook succeeded).
describe "PlaybookParser apply: parsing on include directives" do
  it "parses an include_tasks apply mapping into the include_apply_* fields" do
    playbook = Krikri::PlaybookParser.parse_string(<<-YAML)
      - name: t
        hosts: all
        gather_facts: false
        tasks:
          - name: include with apply
            ansible.builtin.include_tasks:
              file: inner.yml
              apply:
                become: true
                become_user: "{{ some_user }}"
                check_mode: true
                vars:
                  applied: from_apply
                when:
                  - some_flag
                  - other_flag
      YAML

    task = playbook.plays[0].tasks[0]
    task.module_name.must_equal("_include_tasks")
    task.include_apply_become.must_equal(true)
    task.include_apply_become_user.must_equal("{{ some_user }}")
    task.include_apply_check_mode.must_equal(true)
    (task.include_apply_vars || {} of String => JSON::Any)["applied"].as_s.must_equal("from_apply")
    task.include_apply_when.must_equal("(some_flag) and (other_flag)")
    (task.include_apply_when_list || [] of String).must_equal(["some_flag", "other_flag"])
  end

  it "leaves every apply field nil when the include carries no apply:" do
    playbook = Krikri::PlaybookParser.parse_string(<<-YAML)
      - name: t
        hosts: all
        gather_facts: false
        tasks:
          - name: plain include
            ansible.builtin.include_tasks:
              file: inner.yml
      YAML

    task = playbook.plays[0].tasks[0]
    task.include_apply_become.must_be_nil
    task.include_apply_become_user.must_be_nil
    task.include_apply_check_mode.must_be_nil
    task.include_apply_check_mode_expr.must_be_nil
    task.include_apply_vars.must_be_nil
    task.include_apply_when.must_be_nil
    task.include_apply_when_list.must_be_nil
  end

  it "parses apply on include_role, with a templated become: kept as its parse-time value" do
    playbook = Krikri::PlaybookParser.parse_string(<<-YAML)
      - name: t
        hosts: all
        gather_facts: false
        tasks:
          - name: include a role with apply
            ansible.builtin.include_role:
              name: some.role
              apply:
                become: "{{ maybe_become }}"
                become_user: svc
      YAML

    task = playbook.plays[0].tasks[0]
    task.module_name.must_equal("_include_role")
    # Same parse-time guess parse_block_task makes for a block's own
    # templated become: (a `{{ }}` value reads as true).
    task.include_apply_become.must_equal(true)
    task.include_apply_become_user.must_equal("svc")
  end
end
