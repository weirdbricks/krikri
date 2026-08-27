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

    it "keeps a task whose own integer param exceeds Int32 range, instead of silently dropping it with \"Arithmetic overflow\"" do
      # Regression: safe_yaml_to_string/stringify_value both did
      # `yaml.as_i.to_s` - YAML::Any#as_i is Int32-only, so a real
      # (unremarkable) value like a uid: one past Int32::MAX raised
      # "Arithmetic overflow", silently dropping the WHOLE task at parse
      # time. Found via robertdebock.cve_2018_19788's own "Create user"
      # task (uid: 2147483659).
      playbook = <<-YAML
        - name: Example play
          hosts: all
          gather_facts: false
          tasks:
            - name: Create user
              ansible.builtin.user:
                name: cve_2018_19788
                uid: 2147483659
                state: present
        YAML

      result = CrystalPlay::PlaybookParser.parse_string(playbook)

      result.plays[0].tasks.size.should eq(1)
      result.plays[0].tasks[0].params["uid"].should eq("2147483659")
    end

    it "recognizes listen: as a task keyword on a handler, not a module name" do
      # Real bug found benchmarking prometheus.prometheus.node_exporter's
      # own handlers/main.yml: `listen:` wasn't in the special_keys
      # exclusion list module detection scans, so a handler whose YAML
      # happened to list `listen:` before its real module key (`listen:
      # "restart node_exporter"` above `ansible.builtin.systemd: ...`)
      # got "listen" itself picked as the module name - "Plugin not
      # available: listen" - instead of the real ansible.builtin.systemd
      # module underneath it.
      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML)
        - hosts: all
          handlers:
            - name: Restart thing
              listen: "restart thing"
              ansible.builtin.debug:
                msg: restarted
        YAML

      handler = playbook.plays[0].handlers[0]
      handler.module_name.should eq("ansible.builtin.debug")
      handler.listen.should eq("restart thing")
    end

    it "merges args: (a sibling keyword) into a free-form module's params" do
      # Real bug found benchmarking githubixx.ansible_role_wireguard's
      # own public-key derivation: `command: "wg pubkey" / args: {stdin:
      # "{{ key }}"}` - real Ansible's own idiom for extra params on a
      # free-form module (command/shell's stdin:/chdir:/creates:/etc)
      # when the module's own value is a bare command string. args: was
      # not in special_keys at all (risking misdetection as the module
      # name itself) and never merged into task.params regardless -
      # `wg pubkey` always ran with empty stdin, always "Key is not the
      # correct length or format".
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: cat
          args:
            stdin: "hello"
            chdir: /tmp
        YAML

      task.params["stdin"].should eq("hello")
      task.params["chdir"].should eq("/tmp")
    end

    it "does not drop the whole task when become: is a templated string, not a literal boolean" do
      # Real bug found benchmarking ansible-community.ansible-vault's own
      # `become: "{{ vault_privileged_install }}"` - the old `.as_bool`
      # call raised outright for anything that wasn't a literal YAML
      # boolean, and that exception propagated all the way up to
      # parse_tasks' own per-task rescue, silently dropping the ENTIRE
      # task (not just mis-resolving become:) with only a generic "Cast
      # from String to Bool failed" warning nowhere near obviously about
      # become: at all.
      task = single_task(<<-YAML)
        - name: t
          become: "{{ some_var }}"
          ansible.builtin.debug:
            msg: hi
        YAML

      task.name.should eq("t")
      task.become.should be_true
    end

    it "still parses a literal become: boolean normally" do
      task = single_task(<<-YAML)
        - name: t
          become: false
          ansible.builtin.debug:
            msg: hi
        YAML

      task.become.should be_false
    end

    it "lets a task's explicit become: false override a play-level become: true" do
      # Real, deeper pre-existing bug found while fixing the templated-
      # become: crash above (benchmarking ansible-community.ansible-
      # vault): `parse_become_value(...) || play.become` treated an
      # EXPLICIT `become: false` identically to become: being absent
      # entirely, since Bool false and nil are both falsy to `||` - a
      # task deliberately opting OUT of a play-level `become: true`
      # (the role's own "Check Vault package file (local)": `become:
      # false`, delegate_to: 127.0.0.1, explicitly not wanting to sudo
      # for a controller-side stat check) silently kept becoming root
      # anyway - "sudo: a password is required" with no evident tie
      # back to the task's own explicit become: false.
      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - name: play
          hosts: all
          become: true
          tasks:
            - name: opts out
              become: false
              ansible.builtin.debug:
                msg: hi
            - name: inherits play become
              ansible.builtin.debug:
                msg: hi
        YAML
      )

      tasks = playbook.plays[0].tasks
      tasks[0].become.should be_false
      tasks[1].become.should be_true
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

    it "recognizes community.general.gem: (real Ansible's own FQCN for it), not just the bare gem: short name" do
      # Regression: AVAILABLE_PLUGINS registered this as
      # "ansible.builtin.gem" - not a real Ansible module (gem has
      # always lived in community.general, never ansible-core). A bare
      # `gem:` task still happened to resolve via MODULE_SEARCH_
      # COLLECTIONS regardless, but a role writing the fully-qualified
      # `community.general.gem:` form (the far more common style in
      # practice) got "Plugin not available" and the whole task
      # silently dropped, even though plugins/gem.cr is a real, working
      # plugin. Found via robertdebock.travis's own "install travis"
      # task.
      playbook = <<-YAML
        - name: Example play
          hosts: all
          gather_facts: false
          tasks:
            - name: install travis
              community.general.gem:
                name: travis
                state: present
        YAML

      result = CrystalPlay::PlaybookParser.parse_string(playbook)

      result.plays[0].tasks.size.should eq(1)
      result.plays[0].tasks[0].module_name.should eq("community.general.gem")
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

    it "aborts the whole playbook parse for a removed ansible.builtin.include: task, not just skips it" do
      # Real bug found benchmarking robertdebock.awx (round 162): real
      # ansible-core removed the `include:` action entirely after
      # 2023-05-16 and refuses to even START the run when a playbook
      # uses it (rc=1, zero tasks execute) - this previously treated it
      # as merely "Plugin not available: include" (the same soft
      # per-task skip as any not-yet-implemented module) and kept
      # executing every task after it. Verified live against real
      # ansible-playbook 2.19.4: byte-identical error message.
      expect_raises(CrystalPlay::RemovedActionError, /has been removed/) do
        CrystalPlay::PlaybookParser.parse_string(<<-YAML
          - hosts: all
            tasks:
              - name: legacy include
                ansible.builtin.include:
                  file: something.yml
          YAML
        )
      end
    end

    it "also aborts for the bare (non-FQCN) include: spelling" do
      expect_raises(CrystalPlay::RemovedActionError, /has been removed/) do
        CrystalPlay::PlaybookParser.parse_string(<<-YAML
          - hosts: all
            tasks:
              - name: legacy include
                include: something.yml
          YAML
        )
      end
    end

    it "does NOT treat include_vars: (a real, still-valid directive) as the removed include: action" do
      result = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: real task
              ansible.builtin.include_vars:
                file: something.yml
        YAML
      )
      result.plays[0].tasks.size.should eq(1)
    end

    it "keeps a task that uses an unimplemented plugin (marked unavailable_module) instead of dropping it or failing the play" do
      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - name: Uses unavailable plugin
          hosts: all
          tasks:
            - name: Not implemented
              ansible.builtin.mount:
                path: /mnt/data
        YAML
      )

      playbook.plays[0].tasks.size.should eq(1)
      playbook.plays[0].tasks[0].unavailable_module.should eq("ansible.builtin.mount")
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

  describe "notify: handler-name validation is NOT done at parse time" do
    # An unmatched notify: is real Ansible's error only when the
    # notifying task actually fires the notification, at RUN time -
    # verified against ansible-core 2.19.4: a task that reports `ok`
    # (unchanged) or is skipped by its `when:` notifies nothing and the
    # run completes green, even with a notify: naming a handler that
    # exists nowhere. This engine used to reject all three at PARSE
    # time with rc=4, failing playbooks real Ansible runs fine, and
    # simultaneously missed a bad notify inside an include_tasks:-
    # loaded file, which no parse-time sweep can see. The check now
    # lives in TaskExecutor#notify_handlers - see
    # cli_spec.cr's "notify: naming a nonexistent handler" specs for the
    # run-time behavior, and HandlerNotFoundError's own comment.
    it "parses a bare literal notify: target with no matching handler without raising" do
      result = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: touch a file
              ansible.builtin.file:
                path: /tmp/x
                state: touch
              notify: restart httpd
          handlers:
            - name: restart apache2
              ansible.builtin.debug:
                msg: restarted
        YAML
      )
      result.plays[0].tasks.size.should eq(1)
    end

    it "does not raise when the notify: target matches a real handler name" do
      result = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: touch a file
              ansible.builtin.file:
                path: /tmp/x
                state: touch
              notify: restart httpd
          handlers:
            - name: restart httpd
              ansible.builtin.debug:
                msg: restarted
        YAML
      )
      result.plays[0].tasks.size.should eq(1)
    end

    it "does not raise when the notify: target matches a handler's listen: topic" do
      result = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: touch a file
              ansible.builtin.file:
                path: /tmp/x
                state: touch
              notify: webserver restarted
          handlers:
            - name: restart httpd
              listen: webserver restarted
              ansible.builtin.debug:
                msg: restarted
        YAML
      )
      result.plays[0].tasks.size.should eq(1)
    end

    it "does not raise for a templated notify: target (unresolvable statically)" do
      result = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: touch a file
              ansible.builtin.file:
                path: /tmp/x
                state: touch
              notify: "{{ some_handler_var }}"
          handlers:
            - name: unrelated handler
              ansible.builtin.debug:
                msg: restarted
        YAML
      )
      result.plays[0].tasks.size.should eq(1)
    end

    it "does not raise for a role-qualified (' : '-shaped) notify: target" do
      result = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: touch a file
              ansible.builtin.file:
                path: /tmp/x
                state: touch
              notify: "some_role : restart httpd"
          handlers:
            - name: restart httpd
              ansible.builtin.debug:
                msg: restarted
        YAML
      )
      result.plays[0].tasks.size.should eq(1)
    end

    it "does not raise when a play has no handlers: and no tasks notify: anything" do
      result = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: plain task
              ansible.builtin.debug:
                msg: hi
        YAML
      )
      result.plays[0].tasks.size.should eq(1)
    end

    it "finds a matching handler nested inside a block:" do
      result = CrystalPlay::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - block:
                - name: touch a file
                  ansible.builtin.file:
                    path: /tmp/x
                    state: touch
                  notify: restart httpd
          handlers:
            - block:
                - name: restart httpd
                  ansible.builtin.debug:
                    msg: restarted
        YAML
      )
      result.plays[0].tasks.size.should eq(1)
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

    # Real bug found benchmarking konstruktoid.docker_rootless (0.9.621):
    # `become:`/`become_user:` set at the BLOCK level (not on each child
    # task individually - the common "run this whole block as another
    # user" idiom) was never inherited by the nested tasks at all. Each
    # child's own become/become_user resolved only against the PLAY's
    # top-level value (real Ansible's precedence is task > block > role >
    # play), so every task inside silently ran as whatever the play-level
    # default was (usually root) instead of the block's own become_user -
    # found via a block wrapping `systemd_service: {scope: user}`, which
    # then targeted root's own session bus instead of the intended user's,
    # "Unit file ... does not exist" for a unit that genuinely existed
    # under that OTHER user's `~/.config/systemd/user/`.
    it "inherits become:/become_user: from an enclosing block onto its child tasks" do
      task = single_task(<<-YAML)
        - name: my block
          become: true
          become_user: dockeruser
          block:
            - name: inner (no become of its own)
              ansible.builtin.debug:
                msg: hi
        YAML

      inner = task.block_tasks.as(Array(CrystalPlay::Task)).first
      inner.become.should be_true
      inner.become_user.should eq("dockeruser")
    end

    it "lets a child task's own become:/become_user: override the enclosing block's" do
      task = single_task(<<-YAML)
        - name: my block
          become: true
          become_user: dockeruser
          block:
            - name: inner (its own become_user)
              become_user: someoneelse
              ansible.builtin.debug:
                msg: hi
        YAML

      inner = task.block_tasks.as(Array(CrystalPlay::Task)).first
      inner.become.should be_true
      inner.become_user.should eq("someoneelse")
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

    it "keeps an individual bad task inside a block (marked unavailable_module) without failing the whole block" do
      task = single_task(<<-YAML)
        - name: my block
          block:
            - name: good
              ansible.builtin.debug:
                msg: hi
            - name: bad
              ansible.builtin.nope: {}
        YAML

      children = task.block_tasks.as(Array(CrystalPlay::Task))
      children.map(&.name).should eq(["good", "bad"])
      children[1].unavailable_module.should eq("ansible.builtin.nope")
    end
  end

  describe "block/rescue/always in .validate and .stats" do
    it "counts nested block/rescue/always tasks in .stats, not the block pseudo-task itself" do
      stats = CrystalPlay::PlaybookParser.stats(CrystalPlay::PlaybookParser.parse_string(PLAYBOOK_WITH_BLOCK))
      # inner one + inner two + inner three = 3 real tasks; "inner three"
      # uses an unimplemented plugin (ansible.builtin.nope) but is kept
      # (marked unavailable_module) rather than dropped, so it's still
      # counted here same as any other task.
      stats["tasks"].should eq(3)
      stats["modules_used"].should eq(2)
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

    it "raises a fatal StaticImportUndefinedError (aborts the whole playbook) when an import_tasks: path references a fact, not a var/default" do
      # Round172's buluma.php_versions repro (Rocky 9.6), reduced to a
      # minimal case and verified directly against real ansible-playbook:
      # `import_tasks: "setup-{{ ansible_os_family }}.yml"` with no
      # default/var providing ansible_os_family (a facts-only magic var)
      # - real Ansible refuses the WHOLE PLAYBOOK at parse time ("Error
      # when evaluating variable in import path... Static imports cannot
      # use variables from facts... 'ansible_os_family' is undefined",
      # rc=4, zero tasks run). Previously this engine's non-strict
      # substitution silently rendered the missing var as its own
      # "undefined" sentinel ("setup-undefined.yml"), which then just
      # failed to resolve as a file path and was swallowed into a soft
      # "Warning: ... not found" - the play "succeeded" with the import
      # simply missing (ok=0, exit 0) instead of a hard parse failure.
      root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "playbook_parser_import_tasks_fact_path_spec")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
      Dir.mkdir_p(File.join(root, "roles", "myrole", "defaults"))
      File.write(File.join(root, "roles", "myrole", "defaults", "main.yml"), "---\n")
      File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
        - import_tasks: "setup-{{ ansible_os_family }}.yml"
        YAML
      File.write(File.join(root, "roles", "myrole", "tasks", "setup-RedHat.yml"), <<-YAML)
        - name: redhat branch
          ansible.builtin.debug:
            msg: hi
        YAML

      playbook_yaml = <<-YAML
        - name: play
          hosts: all
          roles:
            - myrole
        YAML

      expect_raises(CrystalPlay::StaticImportUndefinedError, /'ansible_os_family' is undefined/) do
        CrystalPlay::PlaybookParser.parse_string(playbook_yaml, File.join(root, "site.yml"))
      end
    end

    it "still resolves an import_tasks: path templated against a real role default (not a fact)" do
      root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "playbook_parser_import_tasks_default_path_spec")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(File.join(root, "roles", "myrole", "tasks"))
      Dir.mkdir_p(File.join(root, "roles", "myrole", "defaults"))
      File.write(File.join(root, "roles", "myrole", "defaults", "main.yml"), "my_variant: Debian\n")
      File.write(File.join(root, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
        - import_tasks: "setup-{{ my_variant }}.yml"
        YAML
      File.write(File.join(root, "roles", "myrole", "tasks", "setup-Debian.yml"), <<-YAML)
        - name: debian branch
          ansible.builtin.debug:
            msg: hi
        YAML

      playbook_yaml = <<-YAML
        - name: play
          hosts: all
          roles:
            - myrole
        YAML

      playbook = CrystalPlay::PlaybookParser.parse_string(playbook_yaml, File.join(root, "site.yml"))

      playbook.plays[0].tasks.map(&.name).should eq(["debian branch"])
    end

    it "raises a hard RoleNotFoundError (rc=1 at the top level) when a role can't be found, matching real Ansible's own immediate refusal" do
      root = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "playbook_parser_missing_role_spec")
      FileUtils.rm_rf(root) if Dir.exists?(root)
      Dir.mkdir_p(root)

      playbook_yaml = <<-YAML
        - name: play
          hosts: all
          roles:
            - does_not_exist
        YAML

      expect_raises(CrystalPlay::RoleNotFoundError, /Role not found/) do
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
      # Round 188: parent `when:` is PREPENDED, not appended, so the
      # cheaper/gate-like operand is evaluated first and `and` can
      # short-circuit the more-expensive one when the gate is false.
      # Real Ansible evaluates `and` left-to-right with short-circuit,
      # so `(foo == "bar") and (other_var == "x")` correctly avoids
      # evaluating `other_var == "x"` when the parent's `foo == "bar"`
      # is false (and vice versa for the old, child-first order which
      # raised an undefined-var on the child when the parent was false).
      tasks[1].when_condition.should eq(%((foo == "bar") and (other_var == "x")))
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

    # Round 188: parent `when:` is PREPENDED, not appended, specifically
    # so `and` can short-circuit. The previous test verifies the
    # string shape; this one verifies the integration-time effect: a
    # gated `import_tasks:` whose child file's last task references a
    # `register:` from a prior inner task that the gate skipped, the
    # whole file is skipped, the child's `when:` is never evaluated,
    # and a strict-undefined reference to a missing registered var
    # does NOT raise. Pre-fix this raised "'item_stat.stat.exists' is
    # undefined" at the child's when-eval, aborting the play; the fix
    # prepends the parent so `(parent) and (child)` short-circuits
    # when the parent is false, exactly like real Ansible.
    it "parent when: false short-circuits the child's when: (no strict-undef on the child operand)" do
      root = import_tasks_root("import_tasks_parent_gate_short_circuits_spec")
      File.write(File.join(root, "inner.yml"), <<-YAML)
        - name: write registered var
          ansible.builtin.set_fact:
            item_stat: {stat: {exists: false}}
        - name: gated by parent AND by self
          ansible.builtin.debug:
            msg: "should be skipped"
          when: not item_stat.stat.exists
        YAML

      playbook = CrystalPlay::PlaybookParser.parse_string(<<-YAML, File.join(root, "site.yml"))
        - name: play
          hosts: all
          gather_facts: false
          tasks:
            - import_tasks: inner.yml
              when: parent_gate | bool
        YAML

      # The child task's when_condition is `(parent) and (child)` -
      # parent FIRST. (Pre-fix it was `(child) and (parent)`.)
      tasks = playbook.plays[0].tasks
      tasks[0].when_condition.should eq(%(parent_gate | bool))
      tasks[1].when_condition.should eq(%((parent_gate | bool) and (not item_stat.stat.exists)))
    end
  end

  describe "module name resolution" do
    # Round 188: a bare `community.crypto.*` short name (e.g.
    # `openssl_privatekey:`) must resolve to the registered
    # `community.crypto.openssl_privatekey` FQCN exactly the way
    # `ansible.builtin.foo` -> `foo` already worked. Bare names are
    # the community-collection idiom (every role tested writes
    # `openssl_privatekey:` / `openssl_csr:` / `openssl_pkcs12:` etc.,
    # not the FQCN), and real Ansible auto-aliases them via the
    # collection-aliasing mechanism. The fix is one line in
    # MODULE_SEARCH_COLLECTIONS: adding "community.crypto" so
    # `#resolve_module_name` tries `community.crypto.<raw>` as a
    # fallback when the bare name isn't directly in AVAILABLE_PLUGINS.
    # Pre-fix the bare name was unresolvable, the role-side task was
    # dropped with a "uses unimplemented plugin" warning, and the
    # `community.crypto modules implemented` 0.9.608 work had
    # arguably unblocked the engine from rc=4 errors but NOT actually
    # run the work - silently skipped, green play, missing the real
    # change.
    describe "community.crypto short names" do
      %w[
        openssl_privatekey
        openssl_csr
        x509_certificate
        openssl_pkcs12
        openssh_keypair
      ].each do |short_name|
        it "resolves bare `#{short_name}:` to community.crypto.#{short_name}" do
          task = single_task(<<-YAML)
            - name: t
              #{short_name}:
                path: /tmp/x
            YAML
          task.module_name.should eq("community.crypto.#{short_name}")
        end
      end
    end

    # The other collections already in MODULE_SEARCH_COLLECTIONS
    # (ansible.builtin/legacy/posix, community.general/docker/
    # mysql/postgresql) were never broken and shouldn't have changed -
    # regression-test the existing behavior alongside the new one.
    describe "other collection short names (regression)" do
      it "resolves bare `apt_key:` to ansible.builtin.apt_key" do
        task = single_task(<<-YAML)
          - name: t
            apt_key:
              url: https://x
          YAML
        task.module_name.should eq("ansible.builtin.apt_key")
      end

      it "resolves bare `docker_container:` to community.docker.docker_container" do
        task = single_task(<<-YAML)
          - name: t
            docker_container:
              name: x
          YAML
        task.module_name.should eq("community.docker.docker_container")
      end
    end

    # Already-resolved FQCNs and `ansible.builtin.*` short names must
    # still work unchanged.
    describe "FQCNs and ansible.builtin are unchanged" do
      it "leaves an explicit FQCN alone" do
        task = single_task(<<-YAML)
          - name: t
            community.crypto.openssl_privatekey:
              path: /tmp/x
          YAML
        task.module_name.should eq("community.crypto.openssl_privatekey")
      end

      it "leaves a bare ansible.builtin.* module alone" do
        task = single_task(<<-YAML)
          - name: t
            ansible.builtin.debug:
              msg: hi
          YAML
        task.module_name.should eq("ansible.builtin.debug")
      end
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

    it "puts vars: into BOTH task.vars (the include's own loop:/when: scope) and task.include_vars (propagated to the included file)" do
      # Real bug found benchmarking round166's buluma.bitbucket on Rocky
      # 9.6: `loop: "{{ query('first_found', _params) }}"` with `vars:
      # {_params: ...}` on the SAME include_tasks: task ("Include release
      # specific tasks") - task.vars stayed empty (only task.include_vars
      # was populated), so build_vars_context never saw `_params` when
      # resolving the include's own loop, which silently resolved to zero
      # items and skipped the whole include - even though the identically-
      # shaped `include_vars:` sibling task with the same `_params` vars:
      # block worked fine.
      task = single_task(<<-YAML)
        - include_tasks: "{{ _loop_var }}"
          loop: "{{ query('first_found', _params) }}"
          loop_control:
            loop_var: _loop_var
          vars:
            _params:
              files: [redhat.yml]
              paths: ["."]
        YAML

      task.vars["_params"]?.should_not be_nil
      task.include_vars.try(&.["_params"]?).should_not be_nil
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

    it "recovers the octal digit text for an unquoted mode: value" do
      # Real bug found benchmarking cloudalchemy.prometheus's own
      # directory/file tasks (mode: 0770, mode: 0644, unquoted - the way
      # most real playbooks write it): YAML 1.1 treats a leading-zero
      # unquoted scalar as octal notation, and Crystal's own YAML parser
      # follows that, silently resolving "0770" to the *decimal* value
      # 504 rather than preserving the literal digit text real Ansible's
      # own YAML loader would. stringify_value's normal Int64 handling
      # then produced the literal string "504", which file.cr's own
      # octal parser (mode.to_i(8)) reinterpreted as MORE octal digits -
      # a chmod of 0o504 instead of the intended 0o770. In one real case
      # this was restrictive enough that the prometheus service user
      # couldn't even read its own config file.
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.file:
            path: /tmp/x
            mode: 0770
        YAML

      task.params["mode"].should eq("0770")
    end

    it "applies the same octal round-trip to a leading-zero-less mode: too, matching real ansible-playbook" do
      # Verified against real ansible-playbook directly: `mode: 644`
      # (no leading zero) parses as plain decimal 644, which Ansible's
      # own file module then ALSO reinterprets via octal conversion -
      # producing mode 1204 (a real, if surprising, well-known Ansible
      # gotcha: "always quote your mode or use a leading 0"), not the
      # literal digits 644. This matches that real behavior exactly
      # rather than trying to "fix" it into something more intuitive.
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.file:
            path: /tmp/x
            mode: 644
        YAML

      task.params["mode"].should eq("01204")
    end

    it "prepends a leading zero so copy.cr/template.cr's own starts_with?(\"0\") octal check still fires" do
      # Real regression caught immediately after the fix above, on the
      # very next task in the same real-host round: Int#to_s(8) never
      # includes a leading zero, but copy.cr and template.cr (unlike
      # file.cr's own regex-based parser, which treats a leading zero as
      # always-optional) branch on `mode.starts_with?("0")` to decide
      # octal-vs-decimal. Without the leading zero, "640" reached
      # template.cr's own parser as a bare *decimal* 640, chmod'ing
      # prometheus's own config file to an unreadable 1200 instead of
      # 0640.
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.template:
            src: x.j2
            dest: /tmp/x
            mode: 0640
        YAML

      task.params["mode"].should eq("0640")
      task.params["mode"].starts_with?("0").should be_true
    end

    it "leaves an explicitly-quoted mode: string untouched" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.file:
            path: /tmp/x
            mode: "0770"
        YAML

      task.params["mode"].should eq("0770")
    end
  end

  describe "legacy inline key=value module args" do
    # Real bug found benchmarking geerlingguy.redis: its handler uses
    # the legacy free-form syntax (`service: "name={{ x }} state=y"`),
    # where a value itself contains `{{ redis_daemon }}` - a Jinja span
    # with its own internal spaces. split_shell_like tokenized on every
    # whitespace character with no awareness of `{{ }}`/`{% %}` as an
    # opaque span, shattering the expression into three bogus tokens
    # (`name={{`, `redis_daemon`, `}}`) - the middle two silently
    # dropped (no `=`), leaving params["name"] as the literal,
    # unrenderable string "{{". The service module then tried to
    # restart a unit literally named "{{".
    it "keeps a {{ }} expression with internal spaces as one token" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.service: "name={{ redis_daemon }} state=restarted"
        YAML

      task.params["name"].should eq("{{ redis_daemon }}")
      task.params["state"].should eq("restarted")
    end

    it "keeps a {% %} statement span with internal spaces as one token" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.debug: "msg={% if x %}yes{% else %}no{% endif %} other=val"
        YAML

      task.params["msg"].should eq("{% if x %}yes{% else %}no{% endif %}")
      task.params["other"].should eq("val")
    end
  end

  describe "command:/shell: trailing special params (creates:/removes:/chdir:/executable:)" do
    # Real bug found benchmarking geerlingguy.firewall's own "Flush
    # iptables the first time playbook runs." task: `command: >
    # iptables -F creates=/etc/firewall.bash`. Real Ansible's command:/
    # shell: modules recognize these as trailing key=value params
    # written inline, stripping them out of the actual command text
    # before running it - previously the ENTIRE string was dumped
    # verbatim into cmd, so "iptables -F creates=/etc/firewall.bash"
    # ran literally and iptables failed trying to interpret
    # "creates=..." as an option/chain name.
    it "extracts a trailing creates= and leaves the rest of the command untouched" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: iptables -F creates=/etc/firewall.bash
        YAML

      task.params["cmd"].should eq("iptables -F")
      task.params["creates"].should eq("/etc/firewall.bash")
    end

    it "extracts multiple trailing special params in any order" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.shell: echo hello chdir=/tmp creates=/tmp/marker
        YAML

      task.params["cmd"].should eq("echo hello")
      task.params["chdir"].should eq("/tmp")
      task.params["creates"].should eq("/tmp/marker")
    end

    it "extracts a trailing special param whose templated value has internal spaces" do
      # Real bug found benchmarking geerlingguy.logstash's own "Get list
      # of installed plugins." task: `./bin/logstash-plugin list
      # chdir={{ logstash_dir }}` - the near-universal `{{ x }}` spacing
      # style. The value alternation only had a quoted-string or bare
      # `\S+` option, and `\S+` only matched up to the template's own
      # leading space ("{{"), leaving "target_dir }}" where `\s*\z`
      # needed pure trailing whitespace - the whole match failed
      # silently, so chdir was never applied at all and the untemplated
      # "chdir={{ logstash_dir }}" text stayed glued onto the command.
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: ./bin/logstash-plugin list chdir={{ logstash_dir }}
        YAML

      task.params["cmd"].should eq("./bin/logstash-plugin list")
      task.params["chdir"].should eq("{{ logstash_dir }}")
    end

    it "extracts a trailing special param with a single template block followed by trailing literal text" do
      # Real bug found benchmarking geerlingguy.solr's own "Run Solr
      # installation script." task: `creates={{ solr_install_path
      # }}/bin/solr` - exactly one `{{ }}` block followed by literal
      # text and no further "}}" anywhere else in the string. The old
      # `\{\{.*?\}\}` alternative only ever matches a single brace
      # pair; it happened to keep working for values with a SECOND
      # template block further along (the lazy `.*?` could backtrack
      # into it), but with only one block and no other "}}" to reach,
      # the whole alternation failed outright, so extraction silently
      # never ran and "creates={{ solr_install_path }}/bin/solr" stayed
      # glued onto the command, running literally.
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: /opt/solr/bin/install_solr_service.sh creates={{ solr_install_path }}/bin/solr
        YAML

      task.params["cmd"].should eq("/opt/solr/bin/install_solr_service.sh")
      task.params["creates"].should eq("{{ solr_install_path }}/bin/solr")
    end

    it "extracts two separate trailing special params, each with its own template block, without one absorbing the other" do
      # Real bug found benchmarking geerlingguy.svn's own "Create a
      # test repository." task: `svnadmin create testrepo chdir={{
      # svn_repository_home }} creates={{ svn_repository_home }}/
      # testrepo/README.txt` - TWO separate key=value params, each with
      # its own `{{ }}` block. The regex-based extraction's `\{\{.*?
      # \}\}` alternative could backtrack straight through the entire
      # `creates=` param (including the space and braces separating it
      # from `chdir=`) to reach ITS closing "}}", so `chdir`'s value
      # absorbed the whole trailing "{{ svn_repository_home }}
      # creates={{ svn_repository_home }}/testrepo/README.txt" as one
      # blob instead of stopping at its own param boundary - `chdir=`
      # failed outright ("No such file or directory") on the resulting
      # not-a-real-path string.
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: svnadmin create testrepo chdir={{ svn_repository_home }} creates={{ svn_repository_home }}/testrepo/README.txt
        YAML

      task.params["cmd"].should eq("svnadmin create testrepo")
      task.params["chdir"].should eq("{{ svn_repository_home }}")
      task.params["creates"].should eq("{{ svn_repository_home }}/testrepo/README.txt")
    end

    it "preserves internal newlines in a multi-statement shell: command, not just a trailing chdir/creates" do
      # Real bug found benchmarking buluma.consul_ca (round 157):
      # extract_command_special_params tokenized the WHOLE raw string
      # via split_shell_like and rejoined the surviving tokens with
      # `.join(" ")` - unconditionally, even when there were no
      # trailing key=value params to strip at all. That collapsed every
      # real newline in a multi-line `shell:` string (a common idiom
      # for readability: `"set -euo pipefail\ncmd1 | cmd2\n"`) into a
      # single space. `set -euo pipefail cmd1 | cmd2` on ONE line means
      # something completely different from real Ansible's two
      # sequential statements: `set` just assigns its trailing words as
      # positional parameters ($1, $2, ...) and does NOT execute them -
      # the actual `cmd1 | cmd2` pipeline the role intended never ran
      # at all, while real ansible-playbook (which never rejoins/
      # re-tokenizes the command string this way) ran it correctly.
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.shell: "echo one\\necho two\\n"
        YAML

      task.params["cmd"].should eq("echo one\necho two\n")
    end

    it "does not corrupt a command containing its own unrelated = text" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: env VAR=1 somecommand
        YAML

      task.params["cmd"].should eq("env VAR=1 somecommand")
      task.params.has_key?("creates").should be_false
    end

    it "leaves a quoted creates= value's spaces intact" do
      task = single_task(<<-YAML)
        - name: t
          ansible.builtin.command: touch somefile creates="/path with spaces/marker"
        YAML

      task.params["cmd"].should eq("touch somefile")
      task.params["creates"].should eq("/path with spaces/marker")
    end
  end
end
