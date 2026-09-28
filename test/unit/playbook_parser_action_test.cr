require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# Round 192 regression cover (stefangweichinger.ansible_rclone): a handler
# using the LEGACY free-form `action: <module> [args]` syntax previously
# made `action` itself the module name; the plugin lookup failed
# ("Plugin binary not found: action") and the exception escaped as an
# unhandled crash of the whole binary. Real Ansible treats `action:` as
# "run this module" - value is `<module> [k=v ...]` or `{module:, args:}`.
describe "Krikri::PlaybookParser (playbook_parser_action_test.cr)" do
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
      task.module_name.must_equal("ansible.builtin.setup")
      task.params.must_equal({} of String => String)
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
      task.module_name.must_equal("ansible.builtin.file")
      task.params["path"].must_equal("/tmp/x")
      task.params["state"].must_equal("touch")
      task.params["mode"].must_equal("0644")
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
      task.module_name.must_equal("ansible.builtin.copy")
      task.params["content"].must_equal("hi")
      task.params["dest"].must_equal("/tmp/x")
    end

    it "parses the dict form action: {module:, ...} with DIRECT sibling params, no args: wrapper (round 812021, cchurch.admin-users)" do
      # Real Ansible's own documented dict-form action:/local_action:
      # syntax: every key other than `module` IS a param directly, no
      # args: nesting required. cchurch.admin-users' own `action:
      # {module: "{{ ansible_pkg_mgr }}", name: ..., state: present}`
      # (templated module name, direct name:/state: siblings) previously
      # dropped name:/state: entirely - only an explicit args: dict was
      # ever read - failing "Missing required parameter: name" even
      # though real Ansible forwards them fine.
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: dict form direct siblings
          hosts: all
          gather_facts: false
          tasks:
            - name: install sudo
              action:
                module: "{{ ansible_pkg_mgr }}"
                name: sudo
                state: present
        YAML
      task = pb.plays[0].tasks[0]
      task.templated_action.must_equal("{{ ansible_pkg_mgr }}")
      task.params["name"].must_equal("sudo")
      task.params["state"].must_equal("present")
    end
  end
end
