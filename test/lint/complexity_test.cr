require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe ComplexityRule do
    private def rule
      ComplexityRule.new
    end

    private def play_yaml(pre_tasks : Int32 = 0, tasks : Int32 = 0,
                          post_tasks : Int32 = 0) : String
      String.build do |str|
        str << "---\n- name: Play\n  hosts: all\n"
        {"pre_tasks" => pre_tasks, "tasks" => tasks,
         "post_tasks" => post_tasks}.each do |section, count|
          next if count.zero?
          str << "  " << section << ":\n"
          count.times do |i|
            str << "    - name: Task " << i << "\n      debug: msg=x\n"
          end
        end
      end
    end

    private def nested_blocks(levels : Int32, via : String? = nil) : String
      String.build do |str|
        str << "---\n- name: Play\n  hosts: all\n  tasks:\n"
        levels.times do |i|
          pad = "    " + ("    " * i)
          str << pad << "- block:\n"
          str << pad << "    - debug: msg=x\n"
          if section = via
            str << pad << "  " << section << ":\n"
            str << pad << "    - debug: msg=y\n"
          end
        end
      end
    end

    it "flags a play whose tasks list exceeds the maximum" do
      v = lint_yaml(rule, play_yaml(tasks: 101), FileType::PLAYBOOK)
      v.size.must_equal(1)
      v.first.rule_id.must_equal("complexity[play]")
      v.first.message.must_equal("Maximum tasks allowed in a play is 100.")
      # Play-level matches point at the play mapping, as upstream does.
      v.first.line.must_equal(2)
      v.first.column.must_equal(3)
    end

    it "allows exactly the maximum number of tasks" do
      v = lint_yaml(rule, play_yaml(tasks: 100), FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "counts neither pre_tasks, post_tasks nor tasks nested in a block" do
      v = lint_yaml(rule, play_yaml(pre_tasks: 101, tasks: 1,
        post_tasks: 101), FileType::PLAYBOOK)
      v.must_be_empty

      yaml = String.build do |str|
        str << "---\n- name: Play\n  hosts: all\n  tasks:\n    - block:\n"
        150.times do |i|
          str << "        - name: Task " << i << "\n          debug: msg=x\n"
        end
      end
      lint_yaml(rule, yaml, FileType::PLAYBOOK).must_be_empty
    end

    it "flags blocks nested deeper than the maximum" do
      v = lint_yaml(rule, nested_blocks(22), FileType::PLAYBOOK)
      v.size.must_equal(1)
      v.first.rule_id.must_equal("complexity[nesting]")
      v.first.line.must_equal(47)
      v.first.column.must_equal(0)
      v.first.message.must_equal(
        "Replace nested block with an include_tasks to make code easier to maintain. " \
        "Maximum block depth allowed is 20.")
    end

    it "allows blocks nested up to the maximum" do
      lint_yaml(rule, nested_blocks(21), FileType::PLAYBOOK).must_be_empty
    end

    it "does not count rescue or always nesting toward the block depth" do
      # Only `block:` sections deepen the nesting; a block reached through
      # a rescue/always section is no deeper than the block owning that
      # section, so a 22-block chain built that way stays within the
      # limit while the same chain built from block: sections does not.
      %w[rescue always].each do |section|
        lint_yaml(rule, nested_blocks(22, via: section),
          FileType::PLAYBOOK).must_be_empty
      end
    end
  end
end
