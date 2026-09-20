require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NoChangedWhenRule do
    rule = NoChangedWhenRule.new

    it "flags a command task with no changed state control" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Run thing
          ansible.builtin.command: /usr/bin/init-thing
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("no-changed-when")
    end

    it "allows changed_when" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Run thing
          ansible.builtin.command: /usr/bin/init-thing
          changed_when: false
        YAML
      v.should be_empty
    end

    it "allows creates" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Run thing
          command: /usr/bin/init-thing
          args:
            creates: /var/lib/thing
        YAML
      v.should be_empty
    end

    it "allows removes" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Clean thing
          command: /usr/bin/clean-thing
          args:
            removes: /var/run/thing.pid
        YAML
      v.should be_empty
    end

    # The installed parity target (ansible-lint 25.2.1) flags these even
    # with async+poll:0; upstream main added an exemption later.
    it "flags async fire-and-forget too (installed-version parity)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Background thing
          command: /usr/bin/long-thing
          async: 300
          poll: 0
        YAML
      v.size.should eq(1)
    end

    it "flags raw and shell modules too" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Raw thing
          raw: cat /proc/cpuinfo
        YAML
      v.size.should eq(1)
    end

    it "does not flag other modules" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          ansible.builtin.apt:
            name: htop
            state: present
        YAML
      v.should be_empty
    end
  end
end
