require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe RiskyFilePermissionsRule do
    private def rule
      RiskyFilePermissionsRule.new
    end

    it "flags file module without mode" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Make dir
          ansible.builtin.file:
            path: /etc/foo
            state: directory
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("risky-file-permissions")
    end

    it "flags a null mode like an absent one, with upstream's shortdesc" do
      # Upstream sees a plain null scalar as Python None, so mode is None
      # and the match message is the rule's shortdesc, not its long
      # description.
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Null mode
          ansible.builtin.file:
            path: /etc/foo
            state: touch
            mode: null
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("File permissions unset or incorrect.")
    end

    it "treats a quoted null mode as present" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Quoted null mode
          ansible.builtin.file:
            path: /etc/foo
            state: touch
            mode: "null"
        YAML
      v.must_be_empty
    end

    it "carries the task line so the report adds the Task/Handler detail" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Make dir
          ansible.builtin.file:
            path: /etc/foo
            state: directory
        YAML
      v.first.task_line.must_equal(2)
      v.first.with_details("Task/Handler: Make dir").details.must_equal("Task/Handler: Make dir")
    end

    it "flags copy module without mode" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Copy config
          ansible.builtin.copy:
            src: foo.conf
            dest: /etc/foo.conf
        YAML
      v.size.must_equal(1)
    end

    it "allows copy with mode" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Copy config
          copy:
            src: foo.conf
            dest: /etc/foo.conf
            mode: "0644"
        YAML
      v.must_be_empty
    end

    it "allows state absent and link" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Remove file
          file:
            path: /etc/foo
            state: absent
        - name: Link file
          file:
            src: /a
            dest: /b
            state: link
        YAML
      v.must_be_empty
    end

    it "allows file module with state file (default)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Touch existing
          file:
            path: /etc/foo
            state: file
        YAML
      v.must_be_empty
    end

    it "allows recurse" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Recurse dir
          file:
            path: /etc/foo
            state: directory
            recurse: true
        YAML
      v.must_be_empty
    end

    it "allows template with mode preserve" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Template foo
          template:
            src: foo.j2
            dest: /etc/foo.conf
            mode: preserve
        YAML
      v.must_be_empty
    end

    it "flags mode preserve on file module (unsupported)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Make dir
          file:
            path: /etc/foo
            state: directory
            mode: preserve
        YAML
      v.size.must_equal(1)
    end

    it "flags lineinfile only when create is true" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Edit line no create
          lineinfile:
            path: /etc/foo
            line: "x=1"
        - name: Edit line with create
          lineinfile:
            path: /etc/bar
            line: "y=2"
            create: true
        YAML
      v.size.must_equal(1)
      v.first.line.must_equal(6)
    end

    it "allows replace without mode (implicit preserve)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Replace text
          replace:
            path: /etc/foo
            regexp: a
            replace: b
        YAML
      v.must_be_empty
    end

    it "does not flag unrelated modules" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          apt:
            name: htop
        YAML
      v.must_be_empty
    end
  end
end
