require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# `static:` is a pre-2.x include-timeout hint that ansible-core still
# parses as a TASK ATTRIBUTE (TaskInclude/IncludeRole only) - it never
# conflicts with the action and never becomes the action itself. Found
# via AerisCloud.repos (round 1200037): its `- include: amazon.yml` +
# `static: no` died here as "conflicting action statements: include,
# static" where ansible-core 2.19.11 refuses the run with the
# include-removed error instead (rc=1); and `- debug:` + `static: no`
# is ansible's own attribute-validation refusal (rc=4, live-verified):
#   'static' is not a valid attribute for a Task
#   This error can be suppressed as a warning using the
#   "invalid_task_attribute_failed" configuration
describe "static: task attribute handling" do
  it "does not conflict with the action, so a bare include: dies as removed" do
    content = "---\n- name: p\n  hosts: web1\n  tasks:\n    - include: amazon.yml\n      static: no\n      when: \"ansible_distribution == 'Amazon'\"\n"
    ex = assert_raises(Krikri::RemovedActionError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.must_equal("The 'ansible.builtin.include' action plugin has been removed. Use include_tasks or import_tasks instead. This feature was removed from ansible-core in a release after 2023-05-16.")
  end

  it "refuses static: beside a non-include action as an invalid attribute" do
    content = "---\n- name: p\n  hosts: web1\n  tasks:\n    - name: bad task\n      ansible.builtin.debug:\n        msg: hi\n      static: no\n"
    ex = assert_raises(Krikri::InvalidTaskAttributeError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.must_equal("'static' is not a valid attribute for a Task\nThis error can be suppressed as a warning using the \"invalid_task_attribute_failed\" configuration")
    ex.render.as(String).lines.first.must_equal("[ERROR]: 'static' is not a valid attribute for a Task")
  end

  it "lets static: ride along on include_tasks (its own TaskInclude validation)" do
    # include_tasks: + static: keeps raising the TaskInclude attribute
    # error from the include parser (not the generic Task one) - same
    # behavior as before this change, now via the non-conflict path.
    content = "---\n- name: p\n  hosts: web1\n  tasks:\n    - include_tasks: other.yml\n      static: no\n"
    ex = assert_raises(Krikri::PlaybookParser::InvalidIncludeAttributeError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.must_equal("'static' is not a valid attribute for a TaskInclude")
  end
end
