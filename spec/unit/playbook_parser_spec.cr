require "../spec_helper"
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
              ansible.builtin.cron:
                job: "true"
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
end
