require "../spec_helper"
require "file_utils"
require "../../src/crystal_play/playbook_parser"

private VALID_PLAYBOOK = <<-YAML
  - name: Example play
    hosts: webservers
    gather_facts: false
    vars:
      greeting: hello
    tasks:
      - name: Say hello
        ansible.builtin.debug:
          msg: "{{ greeting }}"
        register: result
        when: greeting == "hello"
        tags: [demo]
    handlers:
      - name: Restart service
        ansible.builtin.service:
          name: nginx
          state: restarted
  YAML

private PLAYBOOK_WITH_BLOCK = <<-YAML
  - name: play
    hosts: all
    tasks:
      - name: my block
        block:
          - name: inner one
            ansible.builtin.debug:
              msg: one
        rescue:
          - name: inner two
            ansible.builtin.debug:
              msg: two
        always:
          - name: inner three
            ansible.builtin.nope: {}
  YAML

private def import_tasks_root(name : String) : String
  root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", name)
  FileUtils.rm_rf(root) if Dir.exists?(root)
  Dir.mkdir_p(root)
  root
end

private def single_task(task_yaml : String) : CrystalPlay::Task
  task_block = task_yaml.strip.lines.map { |line| "    #{line}" }.join("\n")
  playbook_yaml = "- name: Loop test play\n  hosts: all\n  tasks:\n#{task_block}\n"
  playbook = CrystalPlay::PlaybookParser.parse_string(playbook_yaml)
  playbook.plays[0].tasks[0]
end

describe CrystalPlay::PlaybookParser do
  describe ".parse_string" do
    it "parses plays, tasks and handlers" do
      playbook = CrystalPlay::PlaybookParser.parse_string(VALID_PLAYBOOK)

      playbook.plays.size.should eq(1)
      play = playbook.plays[0]
      play.name.should eq("Example play")
      play.hosts.should eq("webservers")
      play.gather_facts.should be_false
      play.tasks.size.should eq(1)
      play.handlers.size.should eq(1)

      task = play.tasks[0]
      task.module_name.should eq("ansible.builtin.debug")
      task.params["msg"].should eq("{{ greeting }}")
      task.register.should eq("result")
      task.when_condition.should eq(%(greeting == "hello"))
      task.tags.should eq(["demo"])
    end

    it "orders pre_tasks:, roles:, tasks:, and post_tasks: correctly, matching real Ansible" do
      # Real gap found benchmarking every one of geerlingguy.docker/mysql/
      # postgresql/nginx/php/security: pre_tasks:/post_tasks: were
      # entirely unparsed (a documented-in-comment, but not in
      # KNOWN_MISSING.md, simplification) - a play using pre_tasks: for
      # its usual "update apt cache" idiom (the exact shape every one of
      # those roles' own molecule converge.yml uses) silently never ran
      # it at all, with no warning.
      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - name: play
          hosts: all
          pre_tasks:
            - name: pre one
              ansible.builtin.debug:
                msg: pre
          tasks:
            - name: main one
              ansible.builtin.debug:
                msg: main
          post_tasks:
            - name: post one
              ansible.builtin.debug:
                msg: post
        YAML
      )

      play = playbook.plays[0]
      play.tasks.map(&.name).should eq(["pre one", "main one", "post one"])
    end

    it "raises when the only play has no hosts field" do
      # parse_play's error is caught per-play and downgraded to a warning,
      # so a playbook where every play fails to parse surfaces as this
      # top-level error rather than the underlying "missing 'hosts'" message.
      expect_raises(Exception, /No valid plays found/) do
        CrystalPlay::PlaybookParser.parse_string(<<-YAML
          - name: No hosts
            tasks: []
          YAML
        )
      end
    end

    it "raises when the top-level document is not a list" do
      expect_raises(Exception, /must be a YAML list/) do
        CrystalPlay::PlaybookParser.parse_string(<<-YAML
          name: Not a list
          YAML
        )
      end
    end

    it "skips a task that uses an unimplemented plugin instead of failing the play" do
      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - name: Uses unavailable plugin
          hosts: all
          tasks:
            - name: Not implemented
              ansible.builtin.mount:
                path: /mnt/data
        YAML
      )

      playbook.plays[0].tasks.size.should eq(0)
    end

    it "raises when no plays parse successfully" do
      expect_raises(Exception, /No valid plays found/) do
        CrystalPlay::PlaybookParser.parse_string(<<-YAML
          - tasks: []
          YAML
        )
      end
    end
  end

  describe ".validate" do
    it "warns about plays with no tasks" do
      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - name: Empty play
          hosts: all
        YAML
      )

      warnings = CrystalPlay::PlaybookParser.validate(playbook)
      warnings.any?(&.includes?("has no tasks")).should be_true
    end
  end

  describe ".stats" do
    it "counts plays, tasks, handlers and distinct modules" do
      playbook = CrystalPlay::PlaybookParser.parse_string(VALID_PLAYBOOK)
      stats = CrystalPlay::PlaybookParser.stats(playbook)

      stats["plays"].should eq(1)
      stats["tasks"].should eq(1)
      stats["handlers"].should eq(1)
      stats["modules_used"].should eq(2)
    end
  end

  describe "loop parsing" do
    it "parses loop: into loop_items" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item }}"
          loop: [a, b, c]
        YAML

      task.loop_items.try(&.map(&.as_s)).should eq(["a", "b", "c"])
    end

    it "parses with_items: into loop_items (same as loop:)" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item }}"
          with_items: [a, b, c]
        YAML

      task.loop_items.try(&.map(&.as_s)).should eq(["a", "b", "c"])
    end

    it "parses a single-element-array with_items holding a template as a loop template" do
      # `with_items: ["{{ some_list | map(...) | ... }}"]` is the shape roles
      # (dev-sec os_hardening's yum gpg-check) use; Ansible flattens one
      # level so the template (expanding to a list) becomes the items. It
      # must be captured as a runtime-resolved loop template, not treated as
      # one literal item equal to the "{{ ... }}" string.
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.file:
            path: "{{ item }}"
            state: absent
          with_items:
            - "{{ my_list | default([]) | map(attribute='path') | list }}"
        YAML

      task.loop_items.should be_nil
      task.loop_template_kind.should eq("with_items")
      task.loop_template.should eq("{{ my_list | default([]) | map(attribute='path') | list }}")
    end

    it "parses a single-element-array with_items whose item merely embeds a template as a literal loop_items entry, not a loop template" do
      # Real bug found benchmarking geerlingguy.mysql's "Disallow root
      # login remotely": `with_items: ["DELETE FROM mysql.user WHERE
      # User='{{ mysql_root_username }}' AND ..."]` - a single LITERAL
      # loop item whose text happens to embed a template, unlike the
      # spec above where the element IS one bare `{{ ... }}` expression
      # standing for the whole list. The old check (`includes?("{{")`)
      # couldn't tell these apart and always treated this shape as a
      # list-producing template too, so task.loop_items ended up nil and
      # the task ran once with `item` completely unbound ("undefined")
      # instead of once with the rendered SQL string.
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: '{{ item }}'
          with_items:
            - "DELETE FROM mysql.user WHERE User='{{ mysql_root_username }}' AND Host NOT IN ('localhost')"
        YAML

      task.loop_template_kind.should be_nil
      task.loop_items.try(&.size).should eq(1)
      task.loop_items.try(&.first.as_s).should eq(
        "DELETE FROM mysql.user WHERE User='{{ mysql_root_username }}' AND Host NOT IN ('localhost')"
      )
    end

    it "parses loop_control.loop_var onto the task" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.include_tasks: inner.yml
          loop_control:
            loop_var: mount
          loop:
            - { path: /boot }
        YAML

      task.loop_var.should eq("mount")
    end

    it "leaves loop_var nil when no loop_control is given (defaults to item)" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "hi"
          loop: [a, b]
        YAML

      task.loop_var.should be_nil
    end

    it "parses with_dict: into key/value loop_items" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item.key }}={{ item.value }}"
          with_dict:
            one: "1"
            two: "2"
        YAML

      items = task.loop_items.as(Array(JSON::Any))
      items.size.should eq(2)
      items.map(&.["key"].as_s).should eq(["one", "two"])
    end

    it "parses with_nested: into a cartesian-product loop" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item }}"
          with_nested:
            - [a, b]
            - [x, y]
        YAML

      items = task.loop_items.as(Array(JSON::Any))
      items.map(&.as_a.map(&.as_s)).should eq([["a", "x"], ["a", "y"], ["b", "x"], ["b", "y"]])
    end

    it "parses with_sequence: into a numeric range" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item }}"
          with_sequence: "start=1 end=3"
        YAML

      task.loop_items.try(&.map(&.as_s)).should eq(["1", "2", "3"])
    end

    it "parses a bare numeric with_sequence:" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item }}"
          with_sequence: 3
        YAML

      task.loop_items.try(&.map(&.as_s)).should eq(["1", "2", "3"])
    end

    it "parses with_indexed_items: into [index, value] pairs" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item }}"
          with_indexed_items: [x, y]
        YAML

      items = task.loop_items.as(Array(JSON::Any))
      items.map(&.as_a.map(&.as_s)).should eq([["0", "x"], ["1", "y"]])
    end

    it "parses with_fileglob: into raw patterns (resolved at execution time)" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item }}"
          with_fileglob: "/etc/*.conf"
        YAML

      task.loop_fileglob.should eq(["/etc/*.conf"])
      task.loop_items.should be_nil
    end

    it "stashes a variable-referenced loop: as a template for the executor to resolve" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item }}"
          loop: "{{ colors }}"
        YAML

      task.loop_items.should be_nil
      task.loop_template_kind.should eq("loop")
      task.loop_template.should eq("{{ colors }}")
    end

    it "stashes a variable-referenced with_dict: as a template for the executor to resolve" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item.key }}={{ item.value }}"
          with_dict: "{{ some_dict }}"
        YAML

      task.loop_items.should be_nil
      task.loop_template_kind.should eq("with_dict")
      task.loop_template.should eq("{{ some_dict }}")
    end

    it "leaves loop_items nil for a task without any loop source" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hello
        YAML

      task.loop_items.should be_nil
      task.loop_fileglob.should be_nil
    end
  end

  describe "until / retries / delay parsing" do
    it "parses until, retries and delay" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: /bin/true
          register: result
          until: result.rc == 0
          retries: 5
          delay: 2
        YAML

      task.until_condition.should eq("result.rc == 0")
      task.retries.should eq(5)
      task.delay.should eq(2)
    end

    it "defaults retries to 3 and delay to 5 when omitted" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: /bin/true
          register: result
          until: result.rc == 0
        YAML

      task.retries.should eq(3)
      task.delay.should eq(5)
    end
  end

  describe "changed_when / failed_when parsing" do
    it "parses changed_when and failed_when as strings" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: /bin/true
          register: result
          changed_when: result.rc != 0
          failed_when: "'ERROR' in result.stdout"
        YAML

      task.changed_when.should eq("result.rc != 0")
      task.failed_when.should eq("'ERROR' in result.stdout")
    end

    it "parses a bare boolean changed_when: false into the string \"false\"" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: /bin/true
          changed_when: false
        YAML

      task.changed_when.should eq("false")
    end

    it "leaves changed_when and failed_when nil when omitted" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: /bin/true
        YAML

      task.changed_when.should be_nil
      task.failed_when.should be_nil
    end
  end

  describe "delegate_to / run_once parsing" do
    it "parses delegate_to as a string" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hello
          delegate_to: localhost
        YAML

      task.delegate_to.should eq("localhost")
    end

    it "parses a templated delegate_to" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hello
          delegate_to: "{{ target_host }}"
        YAML

      task.delegate_to.should eq("{{ target_host }}")
    end

    it "parses run_once: true" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hello
          run_once: true
        YAML

      task.run_once.should be_true
    end

    it "defaults run_once to false and delegate_to to nil when omitted" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hello
        YAML

      task.run_once.should be_false
      task.delegate_to.should be_nil
    end
  end

  describe "task-level vars: parsing" do
    # Real, previously-shipped bug: nothing in parse_task ever read a
    # plain task's own vars: key into task.vars - only import_tasks:'s
    # separate vars: mechanism was ever wired up. Silently dropped, not
    # an error, so it went unnoticed: VariableContext#build already
    # folds task.vars in at highest priority, so the value was simply
    # invisible everywhere (both {{ }} substitution and bare when:/
    # assert: that:), not just in one code path.

    it "parses a task's own vars: into task.vars" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hello
          vars:
            my_var: 3
        YAML

      task.vars["my_var"]?.try(&.as_i).should eq(3)
    end

    it "parses vars: listed before the module key without it being mistaken for the module name" do
      # special_keys (used to find "the first key that isn't a keyword,
      # that's the module") didn't include "vars" - a task listing vars:
      # before its real module key would have had "vars" itself parsed
      # as the module name instead, failing with "Plugin not available:
      # vars" the moment key order didn't happen to put the module
      # first.
      task = single_task(<<-YAML)
        - name: t
          vars:
            my_var: 3
          ansible.builtin.debug:
            msg: hello
        YAML

      task.module_name.should eq("ansible.builtin.debug")
      task.vars["my_var"]?.try(&.as_i).should eq(3)
    end

    it "keeps task-level vars: scoped to that task only, not shared across tasks" do
      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML)
        - name: p
          hosts: all
          tasks:
            - name: t1
              ansible.builtin.debug:
                msg: hello
              vars:
                my_var: 3
            - name: t2
              ansible.builtin.debug:
                msg: hello
        YAML

      playbook.plays[0].tasks[0].vars["my_var"]?.try(&.as_i).should eq(3)
      playbook.plays[0].tasks[1].vars.has_key?("my_var").should be_false
    end

    it "defaults task.vars to empty when no vars: key is given" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hello
        YAML

      task.vars.should be_empty
    end
  end

  describe "async / poll parsing" do
    it "parses async and poll as integers" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: /bin/true
          async: 30
          poll: 5
        YAML

      task.async_seconds.should eq(30)
      task.poll_seconds.should eq(5)
    end

    it "parses poll: 0 (fire-and-forget) as zero, not nil" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: /bin/true
          async: 30
          poll: 0
        YAML

      task.poll_seconds.should eq(0)
    end

    it "leaves async_seconds and poll_seconds nil when omitted" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: /bin/true
        YAML

      task.async_seconds.should be_nil
      task.poll_seconds.should be_nil
    end
  end

  describe "block / rescue / always parsing" do
    it "parses block: into block_tasks and marks the task as a block" do
      task = single_task(<<-YAML)
        - name: my block
          block:
            - name: inner one
              ansible.builtin.debug:
                msg: one
            - name: inner two
              ansible.builtin.debug:
                msg: two
        YAML

      task.block?.should be_true
      task.module_name.should eq("_block")
      block_tasks = task.block_tasks.as(Array(CrystalPlay::Task))
      block_tasks.map(&.name).should eq(["inner one", "inner two"])
      block_tasks.map(&.module_name).should eq(["ansible.builtin.debug", "ansible.builtin.debug"])
    end

    it "parses rescue: and always: alongside block:" do
      task = single_task(<<-YAML)
        - name: my block
          block:
            - name: risky
              ansible.builtin.command: /bin/false
          rescue:
            - name: recover
              ansible.builtin.debug:
                msg: recovering
          always:
            - name: cleanup
              ansible.builtin.debug:
                msg: cleaning up
        YAML

      task.block_tasks.as(Array(CrystalPlay::Task)).map(&.name).should eq(["risky"])
      task.rescue_tasks.as(Array(CrystalPlay::Task)).map(&.name).should eq(["recover"])
      task.always_tasks.as(Array(CrystalPlay::Task)).map(&.name).should eq(["cleanup"])
    end

    it "leaves rescue_tasks/always_tasks nil when not specified" do
      task = single_task(<<-YAML)
        - name: my block
          block:
            - name: inner
              ansible.builtin.debug:
                msg: hi
        YAML

      task.rescue_tasks.should be_nil
      task.always_tasks.should be_nil
    end

    it "parses when:/ignore_errors:/tags: at the block level" do
      task = single_task(<<-YAML)
        - name: my block
          when: some_var == "yes"
          ignore_errors: true
          tags: [risky]
          block:
            - name: inner
              ansible.builtin.debug:
                msg: hi
        YAML

      task.when_condition.should eq(%(some_var == "yes"))
      task.ignore_errors.should be_true
      task.tags.should eq(["risky"])
    end

    it "supports nested blocks inside a block" do
      task = single_task(<<-YAML)
        - name: outer
          block:
            - name: inner block
              block:
                - name: innermost
                  ansible.builtin.debug:
                    msg: hi
        YAML

      outer_children = task.block_tasks.as(Array(CrystalPlay::Task))
      outer_children.size.should eq(1)
      inner_block = outer_children[0]
      inner_block.block?.should be_true
      inner_block.block_tasks.as(Array(CrystalPlay::Task)).map(&.name).should eq(["innermost"])
    end

    it "skips (with a warning) an individual bad task inside a block without failing the whole block" do
      task = single_task(<<-YAML)
        - name: my block
          block:
            - name: good
              ansible.builtin.debug:
                msg: hi
            - name: bad
              ansible.builtin.nope: {}
        YAML

      task.block_tasks.as(Array(CrystalPlay::Task)).map(&.name).should eq(["good"])
    end
  end

  describe "block/rescue/always in .validate and .stats" do
    it "counts nested block/rescue tasks in .stats, not the block pseudo-task itself" do
      stats = CrystalPlay::PlaybookParser.stats(CrystalPlay::PlaybookParser.parse_string(PLAYBOOK_WITH_BLOCK))
      # inner one + inner two = 2 real tasks; "inner three" fails to parse
      # (unimplemented plugin) so it's dropped before stats ever sees it,
      # same as any other unparseable task.
      stats["tasks"].should eq(2)
      stats["modules_used"].should eq(1)
    end

    it "does not flag the block pseudo-module itself as an unimplemented plugin" do
      # Without recursing into block_tasks, .validate would see module_name
      # "_block" directly (it's deliberately not in AVAILABLE_PLUGINS) and
      # spuriously warn "uses unimplemented plugin: _block" on every block.
      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML)
        - name: play
          hosts: all
          tasks:
            - name: my block
              block:
                - name: inner
                  ansible.builtin.debug:
                    msg: hi
        YAML

      warnings = CrystalPlay::PlaybookParser.validate(playbook)
      warnings.any?(&.includes?("_block")).should be_false
    end
  end

  describe "roles: wiring" do
    it "runs role tasks before the play's own tasks:, in role list order" do
      root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "playbook_parser_roles_spec")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
      File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
        - name: role task
          ansible.builtin.debug:
            msg: from role
        YAML

      playbook_yaml = <<-YAML
        - name: play
          hosts: all
          roles:
            - myrole
          tasks:
            - name: own task
              ansible.builtin.debug:
                msg: from play
        YAML

      playbook = CrystalPlay::PlaybookParser.parse_string(playbook_yaml, File.join(root, "site.yml"))

      playbook.plays[0].tasks.map(&.name).should eq(["role task", "own task"])
    end

    it "templates an import_tasks: file path against the role's own defaults/vars" do
      # Real bug found benchmarking openstack.ansible-hardening: its own
      # tasks/main.yml does `import_tasks: "{{ stig_version }}stig/main.
      # yml"` (stig_version is a plain role default, "rhel7") to pick
      # its OS-versioned STIG control set - 105 of the role's ~112 tasks
      # live behind this one import. import_tasks:'s file path was never
      # templated at all - the literal, unrendered "{{ stig_version
      # }}stig/main.yml" was used directly, always "file not found",
      # silently skipping the entire STIG control set with just a
      # warning (not a hard failure, so easy to miss).
      root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "playbook_parser_import_tasks_templated_path_spec")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks", "rhel7stig"))
      Dir.mkdir_p(File.join(root, "roles", "myrole", "defaults"))
      File.write(File.join(root, "roles", "myrole", "defaults", "main.yml"), "stig_version: rhel7\n")
      File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
        - name: import versioned stig tasks
          import_tasks: "{{ stig_version }}stig/main.yml"
        YAML
      File.write(File.join(root, "roles", "myrole", "tasks", "rhel7stig", "main.yml"), <<-YAML)
        - name: stig task
          ansible.builtin.debug:
            msg: stig ran
        YAML

      playbook_yaml = <<-YAML
        - name: play
          hosts: all
          roles:
            - myrole
        YAML

      playbook = CrystalPlay::PlaybookParser.parse_string(playbook_yaml, File.join(root, "site.yml"))

      playbook.plays[0].tasks.map(&.name).should eq(["stig task"])
    end

    it "raises a warning (not a hard failure) when a role can't be found, matching other unparseable-task handling" do
      root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "playbook_parser_missing_role_spec")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(root)

      playbook_yaml = <<-YAML
        - name: play
          hosts: all
          roles:
            - does_not_exist
        YAML

      expect_raises(Exception, /No valid plays found/) do
        CrystalPlay::PlaybookParser.parse_string(playbook_yaml, File.join(root, "site.yml"))
      end
    end
  end

  describe "import_playbook: wiring" do
    it "splices an imported playbook's plays in place, in order, alongside the importer's own plays" do
      root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "import_playbook_spec")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(root)

      File.write(File.join(root, "webservers.yml"), <<-YAML)
        - name: webservers play
          hosts: all
          tasks:
            - name: webservers task
              ansible.builtin.debug:
                msg: hi
        YAML

      File.write(File.join(root, "site.yml"), <<-YAML)
        - import_playbook: webservers.yml
        - name: main play
          hosts: all
          tasks:
            - name: main task
              ansible.builtin.debug:
                msg: hi
        YAML

      playbook = CrystalPlay::PlaybookParser.parse(File.join(root, "site.yml"))

      playbook.plays.map(&.name).should eq(["webservers play", "main play"])
    end

    it "resolves the imported path relative to the importing playbook's own directory" do
      root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "import_playbook_nested_spec")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(File.join(root, "plays"))

      File.write(File.join(root, "plays", "sub.yml"), <<-YAML)
        - name: sub play
          hosts: all
          tasks: []
        YAML

      File.write(File.join(root, "site.yml"), <<-YAML)
        - import_playbook: plays/sub.yml
        YAML

      playbook = CrystalPlay::PlaybookParser.parse(File.join(root, "site.yml"))

      playbook.plays.map(&.name).should eq(["sub play"])
    end

    it "warns and continues (not a hard failure) when the imported file doesn't exist" do
      root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "import_playbook_missing_spec")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(root)

      File.write(File.join(root, "site.yml"), <<-YAML)
        - import_playbook: does_not_exist.yml
        - name: main play
          hosts: all
          tasks: []
        YAML

      playbook = CrystalPlay::PlaybookParser.parse(File.join(root, "site.yml"))

      playbook.plays.map(&.name).should eq(["main play"])
    end
  end

  describe "import_tasks: wiring" do
    it "splices the imported file's tasks in place (not wrapped in a single pseudo-task)" do
      root = import_tasks_root("import_tasks_spec")
      File.write(File.join(root, "common.yml"), <<-YAML)
        - name: imported one
          ansible.builtin.debug:
            msg: hi
        - name: imported two
          ansible.builtin.debug:
            msg: hi
        YAML

      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML, File.join(root, "site.yml"))
        - name: play
          hosts: all
          tasks:
            - import_tasks: common.yml
            - name: own task
              ansible.builtin.debug:
                msg: hi
        YAML

      playbook.plays[0].tasks.map(&.name).should eq(["imported one", "imported two", "own task"])
    end

    it "applies the import's own when: to each imported task individually, ANDed with any when: the task already has" do
      root = import_tasks_root("import_tasks_when_spec")
      File.write(File.join(root, "common.yml"), <<-YAML)
        - name: unconditioned
          ansible.builtin.debug:
            msg: hi
        - name: already conditioned
          ansible.builtin.debug:
            msg: hi
          when: other_var == "x"
        YAML

      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML, File.join(root, "site.yml"))
        - name: play
          hosts: all
          tasks:
            - import_tasks: common.yml
              when: foo == "bar"
        YAML

      tasks = playbook.plays[0].tasks
      tasks[0].when_condition.should eq(%(foo == "bar"))
      tasks[1].when_condition.should eq(%((other_var == "x") and (foo == "bar")))
    end

    it "applies the import's own tags: to each imported task individually" do
      root = import_tasks_root("import_tasks_tags_spec")
      File.write(File.join(root, "common.yml"), <<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: hi
        YAML

      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML, File.join(root, "site.yml"))
        - name: play
          hosts: all
          tasks:
            - import_tasks: common.yml
              tags: [imported]
        YAML

      playbook.plays[0].tasks[0].tags.should eq(["imported"])
    end

    it "resolves a nested import_tasks: relative to the file that contains it, not the top-level playbook" do
      root = import_tasks_root("import_tasks_nested_spec")
      Dir.mkdir_p(File.join(root, "sub"))
      File.write(File.join(root, "sub", "inner.yml"), <<-YAML)
        - name: innermost task
          ansible.builtin.debug:
            msg: hi
        YAML
      File.write(File.join(root, "sub", "outer.yml"), <<-YAML)
        - import_tasks: inner.yml
        YAML

      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML, File.join(root, "site.yml"))
        - name: play
          hosts: all
          tasks:
            - import_tasks: sub/outer.yml
        YAML

      playbook.plays[0].tasks.map(&.name).should eq(["innermost task"])
    end

    it "warns and continues (not a hard failure) when the imported file doesn't exist" do
      root = import_tasks_root("import_tasks_missing_spec")

      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML, File.join(root, "site.yml"))
        - name: play
          hosts: all
          tasks:
            - import_tasks: does_not_exist.yml
            - name: own task
              ansible.builtin.debug:
                msg: hi
        YAML

      playbook.plays[0].tasks.map(&.name).should eq(["own task"])
    end
  end

  describe "include_tasks: parsing" do
    it "parses a bare-string include_tasks: into a single pseudo-task (not spliced at parse time)" do
      task = single_task(<<-YAML)
        - include_tasks: dynamic.yml
        YAML

      task.include_tasks?.should be_true
      task.module_name.should eq("_include_tasks")
      task.include_file.should eq("dynamic.yml")
    end

    it "parses the file: sub-key form" do
      task = single_task(<<-YAML)
        - include_tasks:
            file: dynamic.yml
        YAML

      task.include_file.should eq("dynamic.yml")
    end

    it "parses when:, tags:, and loop: on the include statement itself" do
      task = single_task(<<-YAML)
        - include_tasks: dynamic.yml
          when: some_var == "yes"
          tags: [dynamic]
          loop: [a, b, c]
        YAML

      task.when_condition.should eq(%(some_var == "yes"))
      task.tags.should eq(["dynamic"])
      task.loop_items.try(&.map(&.as_s)).should eq(["a", "b", "c"])
    end

    it "parses with_first_found: on the include statement itself" do
      # Real bug found benchmarking githubixx.ansible_role_wireguard's
      # own "Include tasks depending on OS" (`include_tasks: {file: "{{
      # item }}"}` paired with with_first_found: candidates, picking the
      # OS-specific setup file to include) - previously unparsed at all
      # (only loop:/with_items: were), so `item` stayed completely
      # unbound and the include's own "{{ item }}" file path rendered to
      # the literal text "undefined", always "file not found".
      task = single_task(<<-YAML)
        - include_tasks:
            file: "{{ item }}"
          with_first_found:
            - "setup-{{ ansible_facts['distribution'] }}.yml"
            - "setup-default.yml"
        YAML

      task.loop_first_found.should eq(["setup-{{ ansible_facts['distribution'] }}.yml", "setup-default.yml"])
    end

    it "does not recurse into the included file's tasks at parse time (dynamic, unlike import_tasks)" do
      task = single_task(<<-YAML)
        - include_tasks: does_not_exist_yet.yml
        YAML

      # No error at parse time even though the file doesn't exist - it's
      # only resolved when this task actually executes.
      task.include_tasks?.should be_true
    end
  end

  describe "include_role: parsing" do
    it "parses name: into include_role_name (not spliced at parse time)" do
      task = single_task(<<-YAML)
        - include_role:
            name: greeter
        YAML

      task.include_role?.should be_true
      task.module_name.should eq("_include_role")
      task.include_role_name.should eq("greeter")
    end

    it "skips (with a warning) an include_role: with no name: rather than failing the whole play" do
      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML)
        - name: play
          hosts: all
          tasks:
            - include_role:
                allow_duplicates: true
        YAML

      playbook.plays[0].tasks.should be_empty
    end

    it "treats vars: as a sibling task keyword, not nested inside include_role: (per ansible-doc)" do
      task = single_task(<<-YAML)
        - include_role:
            name: greeter
          vars:
            target: crystal-ansible
        YAML

      task.include_role_vars.should_not be_nil
      task.include_role_vars.as(Hash(String, JSON::Any))["target"].as_s.should eq("crystal-ansible")
    end

    it "parses when:, tags:, and loop: on the include_role statement itself" do
      task = single_task(<<-YAML)
        - include_role:
            name: greeter
          when: some_var == "yes"
          tags: [dynamic]
          loop: [a, b]
        YAML

      task.when_condition.should eq(%(some_var == "yes"))
      task.tags.should eq(["dynamic"])
      task.loop_items.try(&.map(&.as_s)).should eq(["a", "b"])
    end
  end

  describe "module param encoding" do
    # A plain list (real Ansible's `type: list, elements: str`) stays
    # comma-joined - the format every existing plugin's list params
    # already expect (ports:, volumes:, includepkgs:, ...).
    it "comma-joins a plain scalar list param" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug:
            msg: "{{ item }}"
          loop: [a, b]
        YAML

      other_task = single_task(<<-YAML)
        - name: t
          community.docker.docker_container:
            includepkgs: [foo, bar, baz]
        YAML
      other_task.params["includepkgs"].should eq("foo,bar,baz")
      task.params["msg"].should eq("{{ item }}")
    end

    # A list of dicts (real Ansible's `type: list, elements: dict`, e.g.
    # docker_container's networks:) can't be comma-joined at all - each
    # element's own Hash#to_json output glued together with commas isn't
    # valid JSON once there's more than one element. It's emitted as a
    # real JSON array instead, decodable via `JSON.parse(json).as_a`.
    it "emits a list of dicts as a real JSON array, not comma-joined Hash blobs" do
      task = single_task(<<-YAML)
        - name: t
          community.docker.docker_container:
            networks:
              - name: net-a
                aliases: [alias-a]
              - name: net-b
        YAML

      parsed = JSON.parse(task.params["networks"]).as_a
      parsed.size.should eq(2)
      parsed[0]["name"].as_s.should eq("net-a")
      parsed[0]["aliases"].as_a.map(&.as_s).should eq(["alias-a"])
      parsed[1]["name"].as_s.should eq("net-b")
    end

    it "still emits a single-element dict list as valid JSON (not just a bare Hash blob)" do
      task = single_task(<<-YAML)
        - name: t
          community.docker.docker_container:
            networks:
              - name: solo-net
        YAML

      parsed = JSON.parse(task.params["networks"]).as_a
      parsed.size.should eq(1)
      parsed[0]["name"].as_s.should eq("solo-net")
    end
  end
end
