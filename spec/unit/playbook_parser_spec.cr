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
end
