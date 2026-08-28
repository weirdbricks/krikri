require "../spec_helper"
require "../../src/crystal_play/playbook_parser"

# Round 194 regression cover (andrewrothstein.java-oracle / -jre):
# a sub-include with `become:` / `become_user:` on the include
# statement itself. Real ansible-core 2.19's TaskInclude/IncludeRole
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
# (real ansible's ImportRole inherits the full Task fattributes and
# accepts them).
describe CrystalPlay::PlaybookParser do
  describe "include: directive strict attribute allowlist (round 194)" do
    it "rejects become_user: on include_tasks: like real ansible" do
      expect_raises(CrystalPlay::PlaybookParser::InvalidIncludeAttributeError, /'become_user' is not a valid attribute for a TaskInclude/) do
        CrystalPlay::PlaybookParser.parse_string(<<-YAML)
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

    it "rejects become: on include_tasks: like real ansible" do
      expect_raises(CrystalPlay::PlaybookParser::InvalidIncludeAttributeError, /'become' is not a valid attribute for a TaskInclude/) do
        CrystalPlay::PlaybookParser.parse_string(<<-YAML)
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

    it "rejects become_user: on include_role: like real ansible" do
      expect_raises(CrystalPlay::PlaybookParser::InvalidIncludeAttributeError, /'become_user' is not a valid attribute for a IncludeRole/) do
        CrystalPlay::PlaybookParser.parse_string(<<-YAML)
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

    it "rejects become: on include_role: like real ansible" do
      expect_raises(CrystalPlay::PlaybookParser::InvalidIncludeAttributeError, /'become' is not a valid attribute for a IncludeRole/) do
        CrystalPlay::PlaybookParser.parse_string(<<-YAML)
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
      # These are all on real ansible's VALID_INCLUDE_KEYWORDS, and
      # crystal's existing parser was already happy with them - this
      # test pins that the new allowlist didn't break the common shape.
      pb = CrystalPlay::PlaybookParser.parse_string(<<-YAML)
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
      task.module_name.should eq "_include_tasks"
    end

    it "still accepts become:/become_user: on import_tasks: (real ansible does too)" do
      # Negative case: the allowlist fix must NOT touch import_tasks:
      # - real ansible's ImportPlaybook/ImportRole inherit the full
      # Task fattributes and accept these keys. The patch deliberately
      # scopes the new validation to include_tasks:/include_role: only.
      pb = CrystalPlay::PlaybookParser.parse_string(<<-YAML)
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
      pb.plays.size.should eq 1
    end
  end
end
