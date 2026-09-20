require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe RiskyShellPipeRule do
    rule = RiskyShellPipeRule.new

    it "flags shell pipes without pipefail" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cat x | grep y\n", FileType::PLAYBOOK)
      v.size.should eq(1)
      v.first.message.should eq("Shells that use pipes should set the pipefail option.")
    end

    it "allows pipefail" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: set -o pipefail && cat x | grep y\n", FileType::PLAYBOOK)
      v.should be_empty
    end

    it "ignores double pipes and jinja filters" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cmd1 || cmd2\n    - name: B\n      shell: echo {{ \"x\" | upper }}\n", FileType::PLAYBOOK)
      v.should be_empty
    end

    it "exempts tasks whose ignore_errors is truthy" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cat x | grep y\n      ignore_errors: true\n    - name: B\n      shell: cat x | grep y\n      ignore_errors: yes\n    - name: C\n      shell: cat x | grep y\n      ignore_errors: 1\n", FileType::PLAYBOOK)
      v.should be_empty
    end

    it "still flags falsey ignore_errors" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cat x | grep y\n      ignore_errors: false\n    - name: B\n      shell: cat x | grep y\n      ignore_errors: no\n    - name: C\n      shell: cat x | grep y\n      ignore_errors: 0\n    - name: D\n      shell: cat x | grep y\n", FileType::PLAYBOOK)
      v.size.should eq(4)
    end

    it "exempts quoted and templated ignore_errors like Python truthiness" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      shell: cat x | grep y\n      ignore_errors: \"false\"\n    - name: B\n      shell: cat x | grep y\n      ignore_errors: \"{{ ie }}\"\n", FileType::PLAYBOOK)
      v.should be_empty
    end
  end

  describe IgnoreErrorsRule do
    rule = IgnoreErrorsRule.new

    it "flags truthy ignore_errors without register" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      command: ls\n      ignore_errors: true\n", FileType::PLAYBOOK)
      v.size.should eq(1)
      v.first.message.should contain("Use failed_when and specify error conditions")
    end

    it "allows ignore_errors with register" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      command: ls\n      ignore_errors: true\n      register: r\n", FileType::PLAYBOOK)
      v.should be_empty
    end

    it "allows false ignore_errors" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      command: ls\n      ignore_errors: false\n", FileType::PLAYBOOK)
      v.should be_empty
    end
  end

  describe RunOnceRule do
    it "flags run_once tasks and strategy free plays" do
      rule = RunOnceRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  strategy: free\n  tasks:\n    - name: A\n      command: ls\n      run_once: true\n", FileType::PLAYBOOK)
      v.map(&.rule_id).sort!.should eq(["run-once[play]", "run-once[task]"])
    end

    it "ignores false run_once" do
      rule = RunOnceRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      command: ls\n      run_once: false\n", FileType::PLAYBOOK)
      v.should be_empty
    end
  end

  describe LatestRule do
    it "flags git without version" do
      rule = LatestRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      git:\n        repo: https://x\n", FileType::PLAYBOOK)
      v.map(&.rule_id).should eq(["latest[git]"])
      v.first.message.should eq("Result of the command may vary on subsequent runs.")
    end

    it "allows pinned versions" do
      rule = LatestRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      git:\n        repo: https://x\n        version: v1.0\n", FileType::PLAYBOOK)
      v.should be_empty
    end
  end

  describe PackageLatestRule do
    it "flags state latest without version" do
      rule = PackageLatestRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      apt:\n        name: htop\n        state: latest\n", FileType::PLAYBOOK)
      v.size.should eq(1)
      v.first.message.should eq("Package installs should not use latest.")
    end

    it "allows present and versioned installs" do
      rule = PackageLatestRule.new
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      apt:\n        name: htop\n        state: present\n    - name: B\n      apt:\n        name: htop\n        state: latest\n        version: 1.0\n", FileType::PLAYBOOK)
      v.should be_empty
    end
  end
end
