require "../spec_helper"
require "../../src/krikri/playbook_parser"

# The legacy free-form `local_action: <module> [k=v args]` directive (and
# its `action:` sibling - the action: half has its own round-192 spec):
# previously `local_action` itself became the module name, plugin lookup
# failed, and the task was skipped as an unimplemented plugin (4
# confirming roles: xlab_si.nuage_remove_entity, xlab_si.nuage_create_
# entity, jdauphant.intellij, mrlesmithjr.lsi-megaraid). Real Ansible
# treats it as "run this module on the controller" - the value parses
# exactly like `action:` and the task delegates to localhost.
describe Krikri::PlaybookParser do
  describe "legacy local_action: directive" do
    it "rewrites `local_action: <module> k=v` to the module with parsed args" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: legacy local_action
          hosts: all
          gather_facts: false
          tasks:
            - name: wait for ssh
              local_action: wait_for port=22 host=127.0.0.1
        YAML
      task = pb.plays[0].tasks[0]
      task.module_name.should eq "ansible.builtin.wait_for"
      task.params["port"].should eq "22"
      task.params["host"].should eq "127.0.0.1"
    end

    it "forces delegate_to: localhost" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: legacy local_action delegates to controller
          hosts: all
          gather_facts: false
          tasks:
            - name: touch
              local_action: ansible.builtin.command /usr/bin/touch /tmp/x
        YAML
      pb.plays[0].tasks[0].delegate_to.should eq "localhost"
    end

    it "overrides an explicit delegate_to: with localhost" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: local_action wins over delegate_to
          hosts: all
          gather_facts: false
          tasks:
            - name: touch
              local_action: ansible.builtin.command /usr/bin/true
              delegate_to: otherhost
        YAML
      pb.plays[0].tasks[0].delegate_to.should eq "localhost"
    end

    it "parses the FQCN spelling ansible.builtin.local_action" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: fqcn local_action
          hosts: all
          gather_facts: false
          tasks:
            - name: ping
              ansible.builtin.local_action: ansible.builtin.ping
        YAML
      task = pb.plays[0].tasks[0]
      task.module_name.should eq "ansible.builtin.ping"
      task.delegate_to.should eq "localhost"
    end

    it "parses the dict form local_action: {module:, args:}" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: dict form local_action
          hosts: all
          gather_facts: false
          tasks:
            - name: copy
              local_action:
                module: ansible.builtin.command
                args:
                  argv:
                    - echo
                    - hi
        YAML
      task = pb.plays[0].tasks[0]
      task.module_name.should eq "ansible.builtin.command"
      task.delegate_to.should eq "localhost"
    end

    it "reports the RESOLVED module name in the legacy-key conflict error" do
      # mrlesmithjr.lsi-megaraid: `local_action: wait_for port=22 ...`
      # next to a legacy `sudo:` - real Ansible's ModuleArgsParser
      # resolves the directive first, so the message names wait_for, not
      # the literal local_action key.
      expect_raises(Krikri::ConflictingActionStatementsError, "conflicting action statements: wait_for, sudo") do
        Krikri::PlaybookParser.parse_string(<<-YAML)
          - name: conflict
            hosts: all
            gather_facts: false
            tasks:
              - name: wait
                local_action: wait_for port=22
                sudo: yes
          YAML
      end
    end

    it "keeps a templated module name for run-time resolution instead of marking it unavailable" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: templated action
          hosts: all
          gather_facts: false
          tasks:
            - name: install
              action: "{{ ansible_pkg_mgr }} state=present name={{ item }}"
              with_items:
                - tar
        YAML
      task = pb.plays[0].tasks[0]
      task.templated_action.should eq "{{ ansible_pkg_mgr }} state=present name={{ item }}"
      task.unavailable_module.should be_nil
      task.module_name.should contain("{{")
    end

    it "keeps a templated local_action module name for run-time resolution too" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: templated local_action
          hosts: all
          gather_facts: false
          tasks:
            - name: install
              local_action: "{{ ansible_pkg_mgr }} state=present name=tar"
        YAML
      task = pb.plays[0].tasks[0]
      task.templated_action.should eq "{{ ansible_pkg_mgr }} state=present name=tar"
      task.unavailable_module.should be_nil
      task.delegate_to.should eq "localhost"
    end
  end
end
