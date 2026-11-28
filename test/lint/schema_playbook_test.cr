require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe SchemaPlaybookRule do
    # A fresh unique DIRECTORY, not File.tempname's dirname: with the
    # default tempdir that dirname is /tmp itself, and the rm_rf in the
    # ensure would delete the whole /tmp mid-suite.
    private def playbook_violations(yaml : String) : Array(Violation)
      dir = File.tempname("playbookspec")
      Dir.mkdir(dir)
      path = File.join(dir, "pb.yml")
      File.write(path, yaml)
      file = PositionedFile.load(path)
      violations = [] of Violation
      SchemaPlaybookRule.new.check(file, violations)
      violations
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    # The message is the triple ansible-lint 25.2.1 prints for this file:
    # "$[0].gather_facts 'false' is not of type 'boolean'" at 1:0.
    it "flags a quoted gather_facts" do
      v = playbook_violations(<<-YAML)
        - name: Schema probe
          hosts: all
          gather_facts: "false"
          tasks:
            - name: Say hello
              ansible.builtin.debug:
                msg: hello
        YAML
      v.size.must_equal(1)
      violation = v.first
      violation.rule_id.must_equal("schema[playbook]")
      violation.line.must_equal(1)
      violation.column.must_equal(0)
      violation.message.must_equal("$[0].gather_facts 'false' is not of type 'boolean'")
    end

    # json_path spells an array position [n], so the second play's error
    # names it; jsonschema reports the first best-match error only.
    it "spells a play's index in the json path" do
      v = playbook_violations(<<-YAML)
        - name: First
          hosts: all
          gather_facts: false
        - name: Second
          hosts: all
          gather_facts: "false"
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("$[1].gather_facts 'false' is not of type 'boolean'")
    end

    # A task-level failure spells its list positions and quotes the schema
    # pattern with Python's escapes (backslashes doubled, \n for the real
    # newline the JSON pattern carries), like jsonschema's repr.
    it "quotes a schema pattern the way jsonschema does" do
      v = playbook_violations(<<-YAML)
        - name: Loop probe
          hosts: all
          tasks:
            - name: Bare var loop
              ansible.builtin.debug:
                msg: "{{ item }}"
              with_items: my_var
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        "$[0].tasks[0].with_items 'my_var' does not match " \
        "'^\\\\{[\\\\{%](.|[\\r\\n])*[\\\\}%]\\\\}$'")
    end

    # PyYAML's YAML 1.1 resolver reads the whole-word spellings as
    # booleans, so an unquoted FALSE is a valid gather_facts.
    it "accepts an uppercase boolean spelling" do
      playbook_violations(<<-YAML).must_be_empty
        - name: P
          hosts: all
          gather_facts: FALSE
        YAML
    end

    it "accepts a playbook whose schema is satisfied" do
      playbook_violations(<<-YAML).must_be_empty
        - name: P
          hosts: all
          gather_facts: false
          tasks:
            - name: Say hello
              ansible.builtin.debug:
                msg: hello
        YAML
    end

    # krikri folds upstream's generic yaml kind into PLAYBOOK, so a file
    # no playbook kind pattern names and that holds no plays must stay
    # unvalidated: upstream never upgrades such a lintable to playbook.
    it "skips a generic yaml file that holds no plays" do
      playbook_violations(<<-YAML).must_be_empty
        key: value
        YAML
    end
  end
end
