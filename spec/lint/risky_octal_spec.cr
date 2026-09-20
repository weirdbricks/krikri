require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe RiskyOctalRule do
    rule = RiskyOctalRule.new

    it "flags plain integer mode 0644 (parsed as decimal 644)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 0644
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("risky-octal")
      v.first.message.should contain(%q(mode: "01204"))
    end

    it "flags plain integer 755" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: directory
            mode: 755
        YAML
      v.size.should eq(1)
      v.first.message.should contain(%q(mode: "01363"))
    end

    it "allows quoted mode" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Good mode
          file:
            path: /etc/foo
            state: touch
            mode: "0644"
        YAML
      v.should be_empty
    end

    it "allows symbolic mode" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Symbolic mode
          file:
            path: /etc/foo
            state: touch
            mode: u=rw,g=r,o=r
        YAML
      v.should be_empty
    end

    it "allows true octal integers like 0o755 (parsed decimal 493)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Explicit octal
          file:
            path: /etc/foo
            state: directory
            mode: 0o755
        YAML
      v.should be_empty
    end

    it "does not flag other modules" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Not a file module
          debug:
            msg: 0644
        YAML
      v.should be_empty
    end

    it "handles modes with no mode key" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: No mode
          copy:
            src: a
            dest: /b
        YAML
      v.should be_empty
    end
  end
end
