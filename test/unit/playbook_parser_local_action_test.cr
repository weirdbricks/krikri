require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# The legacy free-form `local_action: <module> [k=v args]` directive (and
# its `action:` sibling - the action: half has its own round-192 spec):
# previously `local_action` itself became the module name, plugin lookup
# failed, and the task was skipped as an unimplemented plugin (4
# confirming roles: xlab_si.nuage_remove_entity, xlab_si.nuage_create_
# entity, jdauphant.intellij, mrlesmithjr.lsi-megaraid). Ansible
# treats it as "run this module on the controller" - the value parses
# exactly like `action:` and the task delegates to localhost.
describe "Krikri::PlaybookParser (playbook_parser_local_action_test.cr)" do
  include RaisesAssertion
  describe "legacy local_action: directive" do
    include RaisesAssertion
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
      task.module_name.must_equal("ansible.builtin.wait_for")
      task.params["port"].must_equal("22")
      task.params["host"].must_equal("127.0.0.1")
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
      pb.plays[0].tasks[0].delegate_to.must_equal("localhost")
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
      pb.plays[0].tasks[0].delegate_to.must_equal("localhost")
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
      task.module_name.must_equal("ansible.builtin.ping")
      task.delegate_to.must_equal("localhost")
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
      task.module_name.must_equal("ansible.builtin.command")
      task.delegate_to.must_equal("localhost")
    end

    it "reports the RESOLVED module name in the legacy-key conflict error" do
      # mrlesmithjr.lsi-megaraid: `local_action: wait_for port=22 ...`
      # next to a legacy `sudo:` - Ansible's ModuleArgsParser
      # resolves the directive first, so the message names wait_for, not
      # the literal local_action key.
      assert_raises_message(Krikri::ConflictingActionStatementsError, "conflicting action statements: wait_for, sudo") do
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

    it "reports a bool type error when a legacy sudo: precedes the module key" do
      # sprylab.tomcat-ubuntu: ansible takes the first non-attribute key
      # (sudo) as the action and type-checks it before apt can conflict.
      assert_raises_message(Krikri::MetaActionTypeError, "unexpected parameter type in action: <class 'bool'>") do
        Krikri::PlaybookParser.parse_string(<<-YAML)
          - name: legacy first
            hosts: all
            gather_facts: false
            tasks:
              - name: install
                sudo: yes
                apt: name=tar
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
      task.templated_action.must_equal("{{ ansible_pkg_mgr }} state=present name={{ item }}")
      task.unavailable_module.must_be_nil
      task.module_name.must_include("{{")
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
      task.templated_action.must_equal("{{ ansible_pkg_mgr }} state=present name=tar")
      task.unavailable_module.must_be_nil
      task.delegate_to.must_equal("localhost")
    end

    # Issue #666 (xlab_si.nuage_create_entity): ansible resolves a
    # MAPPING-form `local_action:`'s module lazily at run time, exactly
    # like a mapping `action:` - so a definitively unresolvable name must
    # not refuse the whole playbook at load (the old behavior, rc=4 with
    # zero tasks run); the name rides the task instead and only fails it
    # if the task is ever reached.
    it "flags a mapping local_action with an unresolvable module instead of refusing the load" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: unresolvable mapping local_action
          hosts: all
          gather_facts: false
          tasks:
            - name: reach nuage
              local_action:
                module: some_unknown_module_xyz
                auth: x
        YAML
      task = pb.plays[0].tasks[0]
      task.unresolvable_mapping_module?.must_equal(true)
      task.unresolvable_mapping_name.must_equal("some_unknown_module_xyz")
      task.unresolvable_mapping_warning.must_be_nil
      # The `module:` VALUE token's own position (the runtime chain's
      # "caused by" Origin) - line 7, column 17 in the heredoc above.
      task.unresolvable_mapping_origin.try { |_, line, col| {line, col} }.must_equal({7, 17})
      # The lazy unavailable_module flow still backs the when:-false skip.
      task.unavailable_module.must_equal("some_unknown_module_xyz")
      task.delegate_to.must_equal("localhost")
    end

    it "flags a mapping action with an unresolvable module the same way" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: unresolvable mapping action
          hosts: all
          gather_facts: false
          tasks:
            - name: reach nuage
              action:
                module: some_unknown_module_xyz
                auth: x
        YAML
      task = pb.plays[0].tasks[0]
      task.unresolvable_mapping_module?.must_equal(true)
      task.unresolvable_mapping_name.must_equal("some_unknown_module_xyz")
      task.delegate_to.must_be_nil
    end

    it "carries the missing-collection warning on an FQCN mapping local_action" do
      # An FQCN whose namespace directory is absent is the shape where
      # ansible-core's loader ALSO prints its "Error loading plugin"
      # [WARNING] before the runtime failure - the executor replays that
      # text from the task's carried warning.
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: unresolvable fqcn mapping local_action
          hosts: all
          gather_facts: false
          tasks:
            - name: reach nuage
              local_action:
                module: absentns.absentcoll.thing
                auth: x
        YAML
      task = pb.plays[0].tasks[0]
      task.unresolvable_mapping_module?.must_equal(true)
      task.unresolvable_mapping_name.must_equal("absentns.absentcoll.thing")
      task.unresolvable_mapping_warning.must_equal(
        "Error loading plugin 'absentns.absentcoll.thing': No module named 'ansible_collections.absentns'")
    end
  end
end
