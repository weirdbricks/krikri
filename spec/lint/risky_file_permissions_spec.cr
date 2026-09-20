require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe RiskyFilePermissionsRule do
    rule = RiskyFilePermissionsRule.new

    it "flags file module without mode" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Make dir
          ansible.builtin.file:
            path: /etc/foo
            state: directory
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("risky-file-permissions")
    end

    it "flags copy module without mode" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Copy config
          ansible.builtin.copy:
            src: foo.conf
            dest: /etc/foo.conf
        YAML
      v.size.should eq(1)
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
      v.should be_empty
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
      v.should be_empty
    end

    it "allows file module with state file (default)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Touch existing
          file:
            path: /etc/foo
            state: file
        YAML
      v.should be_empty
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
      v.should be_empty
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
      v.should be_empty
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
      v.size.should eq(1)
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
      v.size.should eq(1)
      v.first.line.should eq(6)
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
      v.should be_empty
    end

    it "does not flag unrelated modules" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          apt:
            name: htop
        YAML
      v.should be_empty
    end
  end
end
