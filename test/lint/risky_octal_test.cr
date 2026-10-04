require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe RiskyOctalRule do
    private def rule
      RiskyOctalRule.new
    end

    it "treats plain 0644 as octal 420 and does not flag it" do
      # Upstream's YAML loader resolves a leading-zero scalar to an octal
      # int (420 here, a valid mode), so only yaml[octal-values] fires;
      # risky-octal must stay silent.
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 0644
        YAML
      v.must_be_empty
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
      v.size.must_equal(1)
      v.first.message.must_include(%q(mode: "01363"))
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
      v.must_be_empty
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
      v.must_be_empty
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
      v.must_be_empty
    end

    it "parses leading-zero 01204 as octal 644 and flags it like upstream" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 01204
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("risky-octal")
      v.first.message.must_equal(
        %q(`mode: 644` should have a string value with leading zero `mode: "01204"` or use symbolic mode.)
      )
    end

    it "parses 0o124 as octal 84 and flags it like upstream" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 0o124
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        %q(`mode: 84` should have a string value with leading zero `mode: "0124"` or use symbolic mode.)
      )
    end

    it "does not flag 08, which YAML 1.1 leaves a string" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 08
        YAML
      v.must_be_empty
    end

    it "does not flag 0777 or 0666 (valid octal values)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 0777
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 0666
        YAML
      v.must_be_empty
    end

    it "parses binary, hex and underscored forms like upstream" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 0b111
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 0x1a4
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 0_644
        YAML
      # 0b111 is 7, an invalid mode upstream flags; the octal 420s pass.
      v.size.must_equal(1)
      v.first.message.must_equal(
        %q(`mode: 7` should have a string value with leading zero `mode: "07"` or use symbolic mode.)
      )
    end

    it "flags YAML 1.1 sexagesimal 1:2:3 as upstream does" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 1:2:3
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        %q(`mode: 3723` should have a string value with leading zero `mode: "07213"` or use symbolic mode.)
      )
    end

    it "does not flag 1:60, which is not a valid 1.1 sexagesimal" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 1:60
        YAML
      v.must_be_empty
    end

    it "treats YAML booleans as Python True/False modes" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bool mode
          file:
            path: /etc/foo
            state: touch
            mode: true
        - name: False mode
          file:
            path: /etc/foo
            state: touch
            mode: no
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        %q(`mode: True` should have a string value with leading zero `mode: "01"` or use symbolic mode.)
      )
    end

    it "treats single-letter y as a string, not a boolean" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: y mode
          file:
            path: /etc/foo
            state: touch
            mode: y
        YAML
      v.must_be_empty
    end

    it "does not flag negative modes (Python modulo semantics)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Negative mode
          file:
            path: /etc/foo
            state: touch
            mode: -1
        YAML
      v.must_be_empty
    end

    it "flags a negative mode with the same message Python produces" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Negative mode
          file:
            path: /etc/foo
            state: touch
            mode: -644
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        %q(`mode: -644` should have a string value with leading zero `mode: "0-1204"` or use symbolic mode.)
      )
    end

    it "drops the plus sign from a +622 message like Python str does" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Signed mode
          file:
            path: /etc/foo
            state: touch
            mode: +622
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal(
        %q(`mode: 622` should have a string value with leading zero `mode: "01156"` or use symbolic mode.)
      )
    end

    it "does not flag float modes" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Float mode
          file:
            path: /etc/foo
            state: touch
            mode: 644.0
        YAML
      v.must_be_empty
    end

    it "does not flag other modules" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Not a file module
          debug:
            msg: 0644
        YAML
      v.must_be_empty
    end

    it "handles modes with no mode key" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: No mode
          copy:
            src: a
            dest: /b
        YAML
      v.must_be_empty
    end

    it "carries the task line so the report adds the Task/Handler detail" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad mode
          file:
            path: /etc/foo
            state: touch
            mode: 644
        YAML
      v.first.task_line.must_equal(2)
    end
  end
end
