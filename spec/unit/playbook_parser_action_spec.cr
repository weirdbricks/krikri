require "../spec_helper"
require "../../src/krikri/playbook_parser"

# Round 192 regression cover (stefangweichinger.ansible_rclone): a handler
# using the LEGACY free-form `action: <module> [args]` syntax previously
# made `action` itself the module name; the plugin lookup failed
# ("Plugin binary not found: action") and the exception escaped as an
# unhandled crash of the whole binary. Real Ansible treats `action:` as
# "run this module" - value is `<module> [k=v ...]` or `{module:, args:}`.
describe Krikri::PlaybookParser do
  describe "legacy action: directive (round 192)" do
    it "rewrites `action: <module>` to the module with no args" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: legacy action
          hosts: all
          gather_facts: false
          tasks:
            - name: refresh facts
              action: ansible.builtin.setup
        YAML
      task = pb.plays[0].tasks[0]
      task.module_name.should eq "ansible.builtin.setup"
      task.params.should eq({} of String => String)
    end

    it "parses free-form k=v args after the module name" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: legacy action with args
          hosts: all
          gather_facts: false
          tasks:
            - name: touch a file
              action: ansible.builtin.file path=/tmp/x state=touch mode=0644
        YAML
      task = pb.plays[0].tasks[0]
      task.module_name.should eq "ansible.builtin.file"
      task.params["path"].should eq "/tmp/x"
      task.params["state"].should eq "touch"
      task.params["mode"].should eq "0644"
    end

    it "parses the dict form action: {module:, args:}" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: dict form
          hosts: all
          gather_facts: false
          tasks:
            - name: copy
              action:
                module: ansible.builtin.copy
                args:
                  content: hi
                  dest: /tmp/x
        YAML
      task = pb.plays[0].tasks[0]
      task.module_name.should eq "ansible.builtin.copy"
      task.params["content"].should eq "hi"
      task.params["dest"].should eq "/tmp/x"
    end
  end
end
