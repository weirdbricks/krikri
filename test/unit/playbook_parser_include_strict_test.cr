require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "file_utils"

# Round 194 regression cover (andrewrothstein.java-oracle / -jre):
# a sub-include with `become:` / `become_user:` on the include
# statement itself. ansible-core 2.19's TaskInclude/IncludeRole
# parsers validate against a fixed allowlist (TaskInclude's
# VALID_INCLUDE_KEYWORDS frozenset) and reject become:/become_user:
# with
#   "'X' is not a valid attribute for a TaskInclude/IncludeRole"
# at parse time, aborting the whole play (rc=4). Crystal previously
# accepted become:/become_user: on include_tasks:/include_role: -
# parse succeeded, the include ran, then a downstream task failed
# (rc=2, different error), so the two engines diverged on what should
# be an exact same-failure. The andrewrothstein.java-oracle role's
# alpine-glibc-shim dependency has exactly this pattern.
# import_tasks:/import_role: are intentionally NOT validated this way
# (Ansible's ImportRole inherits the full Task fattributes and
# accepts them).
describe "Krikri::PlaybookParser (playbook_parser_include_strict_test.cr)" do
  include RaisesAssertion
  describe "include: directive strict attribute allowlist (round 194)" do
    include RaisesAssertion
    it "rejects become_user: on include_tasks: like Ansible" do
      assert_raises_message(Krikri::PlaybookParser::InvalidIncludeAttributeError, /'become_user' is not a valid attribute for a TaskInclude/) do
        Krikri::PlaybookParser.parse_string(<<-YAML)
          - name: t
            hosts: all
            gather_facts: false
            tasks:
              - name: bad include
                become_user: root
                include_tasks: /dev/null
          YAML
      end
    end

    it "rejects become: on include_tasks: like Ansible" do
      assert_raises_message(Krikri::PlaybookParser::InvalidIncludeAttributeError, /'become' is not a valid attribute for a TaskInclude/) do
        Krikri::PlaybookParser.parse_string(<<-YAML)
          - name: t
            hosts: all
            gather_facts: false
            tasks:
              - name: bad include
                become: yes
                include_tasks: /dev/null
          YAML
      end
    end

    it "rejects become_user: on include_role: like Ansible" do
      assert_raises_message(Krikri::PlaybookParser::InvalidIncludeAttributeError, /'become_user' is not a valid attribute for a IncludeRole/) do
        Krikri::PlaybookParser.parse_string(<<-YAML)
          - name: t
            hosts: all
            gather_facts: false
            tasks:
              - name: bad include_role
                become_user: root
                include_role:
                  name: bogus
          YAML
      end
    end

    it "rejects become: on include_role: like Ansible" do
      assert_raises_message(Krikri::PlaybookParser::InvalidIncludeAttributeError, /'become' is not a valid attribute for a IncludeRole/) do
        Krikri::PlaybookParser.parse_string(<<-YAML)
          - name: t
            hosts: all
            gather_facts: false
            tasks:
              - name: bad include_role
                become: yes
                include_role:
                  name: bogus
          YAML
      end
    end

    it "accepts allowed attrs on include_tasks: (when:/tags:/loop:/vars:/register:)" do
      # These are all on Ansible's VALID_INCLUDE_KEYWORDS, and
      # crystal's existing parser was already happy with them - this
      # test pins that the new allowlist didn't break the common shape.
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: t
          hosts: all
          gather_facts: false
          tasks:
            - name: good include
              when: ansible_os_family == 'Debian'
              tags: [setup, base]
              loop: ["a.yml", "b.yml"]
              vars: {x: 1}
              register: r
              include_tasks: "{{ item }}"
        YAML
      task = pb.plays[0].tasks[0]
      task.module_name.must_equal("_include_tasks")
    end

    it "still accepts become:/become_user: on import_tasks: (Ansible does too)" do
      # Negative case: the allowlist fix must NOT touch import_tasks:
      # - Ansible's ImportPlaybook/ImportRole inherit the full
      # Task fattributes and accept these keys. The patch deliberately
      # scopes the new validation to include_tasks:/include_role: only.
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: t
          hosts: all
          gather_facts: false
          tasks:
            - name: import with become
              become: yes
              become_user: root
              import_tasks: /dev/null
        YAML
      # parse_string returned without raising - that's the assertion.
      # (import_tasks:'s tasks don't actually run since /dev/null is
      # empty; parse-time splice is what we care about here.)
      pb.plays.size.must_equal(1)
    end

    it "rejects notify: on include_tasks: like Ansible" do
      # notify: was on TASK_INCLUDE_VALID_KEYWORDS until
      # juju4.ansible_role_mattermost's own `include_tasks: selinux.yml`
      # with a notify: on the include line itself (RHEL-family round
      # 60113) turned out to hit exactly this predicted gap live -
      # ansible-core's actual VALID_INCLUDE_KEYWORDS (verified
      # directly, not assumed) does not include it. A task's own
      # notify: elsewhere (on an ordinary task, including one inside
      # an included file) is unaffected - only the include directive
      # line itself notifying anything is invalid.
      assert_raises_message(Krikri::PlaybookParser::InvalidIncludeAttributeError, /'notify' is not a valid attribute for a TaskInclude/) do
        Krikri::PlaybookParser.parse_string(<<-YAML)
          - name: t
            hosts: all
            gather_facts: false
            tasks:
              - include_tasks: /dev/null
                notify: restart something
          YAML
      end
    end

    it "renders the Origin block at the task's position for a disallowed include key" do
      # issue #156: ansible-core prints the full [ERROR]/Origin block for
      # a disallowed include attribute, with the Origin at the TASK's
      # mapping start (line 5, column 7 = the `- name:` key of the task
      # dict in the playbook below, live-verified vs 2.19.11) - not at
      # the offending key's own column, and without the
      # "This error can be suppressed..." line that the `static:`
      # refusal carries (that line only appears for the static: case).
      # The allowlist path used to raise with no render at all, so
      # krikri printed only the [ERROR] line. parse_string can't carry
      # a source map, so write a real playbook file like
      # include_directive_args_test.cr does.
      root = PluginSpecHelper.tmp_path("include_strict_origin")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(root)
      path = File.join(root, "site.yml")
      File.write(path, <<-YAML)
        - name: t
          hosts: all
          gather_facts: false
          tasks:
            - name: bad include
              become: yes
              include_tasks: /dev/null
        YAML

      ex = assert_raises(Krikri::PlaybookParser::InvalidIncludeAttributeError) do
        Krikri::PlaybookParser.parse(File.expand_path(path))
      end
      render = ex.render.as(String)
      render.must_include("[ERROR]: 'become' is not a valid attribute for a TaskInclude\n")
      render.must_include("Origin: #{File.expand_path(path)}:5:7\n")
      render.must_include("^ column 7\n")
      render.wont_include("This error can be suppressed")
    end
  end
end
