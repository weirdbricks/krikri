require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NoRelativePathsRule do
    private def rule
      NoRelativePathsRule.new
    end

    it "flags copy and template src climbing into their own folders" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: Copy
              ansible.builtin.copy:
                src: ../files/a.txt
                dest: /tmp/a
            - name: Template
              ansible.builtin.template:
                src: ../templates/b.j2
                dest: /tmp/b
        YAML
      v.size.must_equal(2)
      v.map { |violation| {violation.line, violation.column} }.must_equal([{5, 0}, {9, 0}])
      v.each do |violation|
        violation.rule_id.must_equal("no-relative-paths")
        violation.severity.must_equal(Severity::HIGH)
        violation.message.must_equal("The src argument should not use a relative path.")
        violation.task_line.must_equal(violation.line)
      end
    end

    it "does not flag the other module's folder" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: Copy from templates
              ansible.builtin.copy:
                src: ../templates/a.txt
                dest: /tmp/a
            - name: Template from files
              ansible.builtin.template:
                src: ../files/b.j2
                dest: /tmp/b
        YAML
      v.must_be_empty
    end

    it "flags the windows modules by their short names" do
      v = lint_yaml(rule, <<-'YAML')
        ---
        - name: Play
          hosts: all
          tasks:
            - name: Win copy
              win_copy:
                src: ../files/a.txt
                dest: C:\a
            - name: Win template
              win_template:
                src: ../win_templates/b.j2
                dest: C:\b
            - name: Win template from templates
              win_template:
                src: ../templates/c.j2
                dest: C:\c
        YAML
      v.map(&.line).must_equal([5, 9])
    end

    it "ignores unresolved collection and legacy fqcn spellings" do
      # 25.2.1 leaves these __ansible_module__ values as written, so its
      # map of short names never matches them.
      v = lint_yaml(rule, <<-'YAML')
        ---
        - name: Play
          hosts: all
          tasks:
            - name: Windows copy
              ansible.windows.win_copy:
                src: ../files/a.txt
                dest: C:\a
            - name: Legacy copy
              ansible.legacy.copy:
                src: ../files/b.txt
                dest: /tmp/b
        YAML
      v.must_be_empty
    end

    it "leaves unarchive and script src alone" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: Unpack
              ansible.builtin.unarchive:
                src: ../files/a.tgz
                dest: /tmp/a
            - name: Run script
              ansible.builtin.script:
                cmd: ../files/b.sh
        YAML
      v.must_be_empty
    end

    it "reads only the action's own src, not a task-level args src" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: Copy with args
              ansible.builtin.copy:
                dest: /tmp/a
                args:
                  src: ../files/a.txt
        YAML
      v.must_be_empty
    end

    it "allows absolute and plain relative paths" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: Absolute
              ansible.builtin.copy:
                src: /srv/files/a.txt
                dest: /tmp/a
            - name: Plain
              ansible.builtin.copy:
                src: files/b.txt
                dest: /tmp/b
        YAML
      v.must_be_empty
    end

    it "matches upstream's literal substring test" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: Folder prefix
              ansible.builtin.copy:
                src: ../filesx/a.txt
                dest: /tmp/a
            - name: Embedded jinja
              ansible.builtin.copy:
                src: "{{ base }}/../files/b.txt"
                dest: /tmp/b
        YAML
      v.map(&.line).must_equal([5, 9])
    end
  end
end
