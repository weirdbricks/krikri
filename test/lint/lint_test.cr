require "../minitest_helper"
require "file_utils"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe PositionedFile do
    it "parses a valid file and exposes position data" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- name: x\n  apt:\n    state: present\n")
      begin
        file = PositionedFile.load(path)
        file.parse_error.must_be_nil
        root = file.root.as(YAML::Nodes::Node)
        root.must_be_instance_of(YAML::Nodes::Sequence)
        first = root.as(YAML::Nodes::Sequence).nodes.first
        NodeUtil.line(first).must_equal(2)
        NodeUtil.column(first).must_equal(3)
      ensure
        File.delete(path)
      end
    end

    it "captures parse errors with line/column" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "tasks:\n  - name: bad\n  [oops\n")
      begin
        file = PositionedFile.load(path)
        file.root.must_be_nil
        err = file.parse_error.as(PositionedFile::ParseErrorInfo)
        expect((err.line) > (0)).must_equal(true)
      ensure
        File.delete(path)
      end
    end

    it "classifies role file types from path" do
      FileType.from_path("roles/foo/tasks/main.yml").must_equal(FileType::TASKS)
      FileType.from_path("roles/foo/handlers/main.yml").must_equal(FileType::HANDLERS)
      FileType.from_path("roles/foo/meta/main.yml").must_equal(FileType::META)
      FileType.from_path("site.yml").must_equal(FileType::PLAYBOOK)
    end

    it "leaves a path no kind pattern matches unknown" do
      # ansible-lint's kind_from_path returns an empty kind here and
      # runs no rules on the lintable.
      FileType.from_path("playbook").must_equal(FileType::UNKNOWN)
      FileType.from_path("notes.txt").must_equal(FileType::UNKNOWN)
    end

    it "prepends a config's kinds to the default patterns" do
      kinds = [KindPattern.new("tasks", "**/custom.yml")]
      FileType.from_path("roles/foo/custom.yml", kinds).must_equal(FileType::TASKS)
      # The project pattern wins even where a role subdirectory would
      # otherwise decide the kind.
      FileType.from_path("roles/foo/tasks/custom.yml", kinds).must_equal(FileType::TASKS)
      FileType.from_path("other.yml", kinds).must_equal(FileType::PLAYBOOK)
    end

    it "keeps a kind it has no rules for unknown" do
      kinds = [KindPattern.new("python", "**/*.py")]
      FileType.from_path("library/module.py", kinds).must_equal(FileType::UNKNOWN)
    end

    it "only gives a text/yaml base kind to yaml file names" do
      # Upstream assigns the base kind from the name alone; it gates the
      # yaml/task rule dispatch independently of the explicit kind.
      PositionedFile.new("site.yml", FileType::PLAYBOOK, nil, nil).base_yaml?.must_equal(true)
      PositionedFile.new("demo.play", FileType::PLAYBOOK, nil, nil).base_yaml?.must_equal(false)
    end
  end

  describe NodeUtil do
    it "iterates mapping entries from the flat node list" do
      parsed = YAML::Nodes.parse("a: 1\nb: two\n")
      mapping = parsed.nodes.first.as(YAML::Nodes::Mapping)
      keys = [] of String
      NodeUtil.each_entry(mapping) do |k, v|
        keys << "#{NodeUtil.scalar_value(k)}=#{NodeUtil.scalar_value(v)}"
      end
      keys.must_equal(["a=1", "b=two"])
    end

    it "finds an entry by key" do
      parsed = YAML::Nodes.parse("name: hello\napt: {}\n")
      mapping = parsed.nodes.first.as(YAML::Nodes::Mapping)
      found = NodeUtil.entry(mapping, "name").as({YAML::Nodes::Node, YAML::Nodes::Node})
      NodeUtil.scalar_value(found[1]).must_equal("hello")
      NodeUtil.entry(mapping, "missing").must_be_nil
    end
  end

  describe FileDiscovery do
    it "finds yaml files recursively, skipping non-lintable dirs" do
      dir = File.tempname("lintdisc")
      Dir.mkdir(dir)
      Dir.mkdir(File.join(dir, "tasks"))
      Dir.mkdir(File.join(dir, "files"))
      File.write(File.join(dir, "play.yml"), "---\n")
      File.write(File.join(dir, "tasks", "main.yaml"), "---\n")
      File.write(File.join(dir, "files", "skip.yml"), "---\n")
      File.write(File.join(dir, "ignored.txt"), "x")
      begin
        FileDiscovery.discover([dir]).sort.must_equal([
          File.join(dir, "play.yml"),
          File.join(dir, "tasks", "main.yaml"),
        ])
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "accepts a single file target as-is" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n")
      begin
        FileDiscovery.discover([path]).must_equal([path])
      ensure
        File.delete(path)
      end
    end

    it "reports a missing target instead of exiting" do
      dir = File.tempname("lintdisc")
      Dir.mkdir(dir)
      begin
        missing = FileDiscovery.missing_targets([File.join(dir, "gone.yml")])
        missing.must_equal([File.join(dir, "gone.yml")])
        FileDiscovery.discover([File.join(dir, "gone.yml")]).must_be_empty
        FileDiscovery.missing_targets([dir]).must_be_empty
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe LoadFailureRule do
    private def rule
      LoadFailureRule.new
    end

    it "reports a parse failure as a warning-level load-failure on line 1" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "tasks:\n  - name: bad\n  [oops\n")
      begin
        file = PositionedFile.load(path)
        violations = [] of Violation
        rule.check(file, violations)
        violations.size.must_equal(1)
        v = violations.first
        v.rule_id.must_equal("load-failure[runtimeerror]")
        v.line.must_equal(1)
        v.column.must_equal(0)
        v.level.must_equal("warning")
        v.warning?.must_equal(false) # still counts as a failure
        v.message.must_equal("Failed to load YAML file: #{File.expand_path(path)}")
      ensure
        File.delete(path)
      end
    end

    it "stays silent on a clean or empty file" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "")
      begin
        file = PositionedFile.load(path)
        violations = [] of Violation
        rule.check(file, violations)
        violations.must_be_empty
      ensure
        File.delete(path)
      end
    end
  end

  describe Outcome do
    it "breaks same-position ties by rule id, like upstream" do
      a = Violation.new("p.yml", 9, 0, "no-changed-when", Severity::HIGH, "m")
      b = Violation.new("p.yml", 9, 0, "name[missing]", Severity::MEDIUM, "m")
      c = Violation.new("p.yml", 9, 0, "command-instead-of-shell", Severity::HIGH, "m")
      Outcome.sort([a, b, c]).map(&.rule_id).must_equal([
        "command-instead-of-shell", "name[missing]", "no-changed-when",
      ])
    end

    it "keeps a missing target's load-failure pair in upstream order" do
      a = Violation.new("gone.yml", 1, 0, "load-failure[filenotfounderror]", Severity::VERY_HIGH, "m", nil, false, "None", "warning")
      b = Violation.new("gone.yml", 1, 0, "load-failure[not-found]", Severity::VERY_HIGH, "m", nil, false, "", "warning")
      Outcome.sort([a, b]).map(&.rule_id).must_equal([
        "load-failure[not-found]", "load-failure[filenotfounderror]",
      ])
    end

    it "only reports skippable rules as printable ignore-docs targets" do
      registry = RuleRegistry.default
      load_failure = [Violation.new("gone.yml", 1, 0, "load-failure[not-found]",
        Severity::VERY_HIGH, "m", nil, false, "", "warning")]
      Outcome.skippable?(load_failure, registry).must_equal(false)
      yaml = [Violation.new("a.yml", 1, 0, "yaml[colons]", Severity::LOW, "m")]
      Outcome.skippable?(yaml, registry).must_equal(true)
    end
  end

  describe RuleRegistry do
    it "lists rules with ids" do
      registry = RuleRegistry.default
      registry.find("load-failure").wont_be_nil
      registry.find("nope").must_be_nil
    end
  end

  describe Runner do
    it "collects violations across targets" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "  [broken\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        violations.size.must_equal(1)
      ensure
        File.delete(path)
      end
    end

    it "reports nothing for an explicitly named file with an unknown kind" do
      # ansible-lint lints an extensionless playbook target but its
      # kind resolution leaves it with no kind, so no rule applies.
      path = File.tempname("lintspec")
      File.write(path, "---\n- name: extension demo\n  hosts: localhost\n  tasks:\n" \
                        + "    - name: say hello\n      ansible.builtin.debug:\n" \
                           + "        msg: hello\n")
      begin
        Runner.new(RuleRegistry.default).run([path]).must_be_empty
      ensure
        File.delete(path)
      end
    end

    it "describes a task-scoped match with its task, like upstream" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- name: Play\n  hosts: localhost\n  tasks:\n" \
                        + "    - name: Install pkg\n      ansible.builtin.apt:\n" \
                           + "        name: nginx\n        state: latest\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        latest = violations.find { |v| v.rule_id == "package-latest" }
        raise "no package-latest violation" unless latest
        latest.details.must_equal("Task/Handler: Install pkg")
      ensure
        File.delete(path)
      end
    end

    it "leaves file-level matches without a task detail" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- name:  Play\n  hosts: localhost\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        yaml_match = violations.find { |v| v.rule_id == "yaml[colons]" }
        raise "no yaml[colons] violation" unless yaml_match
        yaml_match.details.must_equal("")
      ensure
        File.delete(path)
      end
    end

    it "falls back to the module and free-form args for an unnamed task" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- hosts: localhost\n  tasks:\n    - import_tasks: tasks/x.yml\n")
      begin
        file = PositionedFile.load(path)
        task = TaskWalker.collect_tasks(file).first
        raise "no task found" unless task
        task.display_name.must_equal("import_tasks tasks/x.yml")
      ensure
        File.delete(path)
      end
    end

    it "renders an argumentless unnamed task with upstream's trailing space" do
      # Upstream joins f"{module} {' '.join(args)}", so the space after
      # the module stays even with no arguments. Verified against
      # ansible-lint 25.2.1: "Task/Handler: ping ".
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- hosts: localhost\n  tasks:\n    - ping:\n")
      begin
        file = PositionedFile.load(path)
        task = TaskWalker.collect_tasks(file).first
        raise "no task found" unless task
        task.display_name.must_equal("ping ")
      ensure
        File.delete(path)
      end
    end

    it "attaches the trailing-space detail to an unnamed task's matches" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- hosts: localhost\n  tasks:\n    - ansible.builtin.ping:\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        missing = violations.find { |v| v.rule_id == "name[missing]" }
        raise "no name[missing] violation" unless missing
        missing.details.must_equal("Task/Handler: ping ")
      ensure
        File.delete(path)
      end
    end

    it "reports only the syntax-check match on a file whose module the controller cannot resolve" do
      # Upstream runs no rules at all on a file whose
      # `ansible-playbook --syntax-check` fails: an unnamed play around
      # an unresolvable module reports only syntax-check[unknown-module]
      # from ansible-lint 25.2.1 - no name[play], no name[missing], no
      # yaml[*], nothing else.
      dir = PluginSpecHelper.tmp_path("lint_syntax_gate")
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "play.yml")
      File.write(path, "---\n- hosts: all\n  tasks:\n" \
                        + "    - name: P1\n      krikri_lint_unknown_mod:\n")
      violations = Runner.new(RuleRegistry.default).run([path])
      violations.map(&.rule_id).must_equal(["syntax-check[unknown-module]"])
    end

    it "does not flag krikri's own json_file extension module as unknown" do
      # json_file is not an Ansible module, so the captured reference tables
      # cannot place it - but krikri-playbook runs it, so lint must not
      # refuse the playbook ansible-playbook would (issue #1835).
      dir = PluginSpecHelper.tmp_path("lint_syntax_extension")
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "play.yml")
      File.write(path, "---\n- name: Play one\n  hosts: all\n  tasks:\n" \
                        + "    - name: P1\n      json_file:\n        path: /tmp/x.json\n        key: a\n        value: 1\n        mode: \"0644\"\n")
      violations = Runner.new(RuleRegistry.default).run([path])
      violations.map(&.rule_id).must_equal([] of String)
    end

    it "reports syntax-check[unknown-module] where ansible's own error points" do
      # ansible-playbook --syntax-check names the first task whose module
      # it cannot resolve: the task mapping's position (an unnamed task
      # points at its module key, a named one at `name`, column 7 here)
      # and the name exactly as written.
      dir = PluginSpecHelper.tmp_path("lint_syntax_match")
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "play.yml")
      File.write(path, "---\n- hosts: all\n  tasks:\n" \
                        + "    - name: P1\n      krikri_lint_missing_mod:\n")
      violations = Runner.new(RuleRegistry.default).run([path])
      violations.size.must_equal(1)
      match = violations.first
      match.rule_id.must_equal("syntax-check[unknown-module]")
      {match.line, match.column}.must_equal({4, 7})
      match.message.must_equal("couldn't resolve module/action " \
                               "'krikri_lint_missing_mod'. This often indicates a misspelling, " \
                               "missing collection, or incorrect module path.")
    end

    it "registers the syntax-check rule" do
      # The runner's gate reports the match, but the rule still has to
      # be registered for --list-rules and the profile/skip lookups.
      rule = RuleRegistry.default.find("syntax-check")
      raise "syntax-check is not registered" unless rule
      rule.tags.must_equal(["core", "unskippable"])
    end

    it "keeps linting when the module resolves from the playbook's library/ dir" do
      # The same play around a module the controller CAN resolve - a
      # playbook-private library/ source is part of the load-time
      # lookup - reports name[play] from ansible-lint 25.2.1, so the
      # syntax-check gate must not fire on it.
      dir = PluginSpecHelper.tmp_path("lint_library_gate")
      FileUtils.mkdir_p(File.join(dir, "library"))
      File.write(File.join(dir, "library", "my_custom_mod.py"), "# fixture\n")
      path = File.join(dir, "play.yml")
      File.write(path, "---\n- hosts: all\n  tasks:\n" \
                        + "    - name: P1\n      my_custom_mod:\n")
      violations = Runner.new(RuleRegistry.default).run([path])
      play_match = violations.find { |v| v.rule_id == "name[play]" }
      raise "no name[play] violation" unless play_match
    end

    it "reports only the syntax-check match on a playbook whose module names the controller cannot resolve" do
      # Upstream: the unresolvable `krikri_ok` fails ansible's playbook
      # syntax check (syntax-check[unknown-module]) and no other rule
      # runs on the file - verified against ansible-lint 25.2.1.
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- hosts: localhost\n  tasks:\n" \
                        + "    - krikri_ok:\n" \
                           + "    - ansible.builtin.debug:\n        msg: hi\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        violations.map(&.rule_id).must_equal(["syntax-check[unknown-module]"])
      ensure
        File.delete(path)
      end
    end

    it "still reports a playbook whose module names resolve" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- hosts: localhost\n  tasks:\n" \
                        + "    - ansible.builtin.ping:\n" \
                           + "    - ansible.builtin.debug:\n        msg: hi\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        violations.count { |v| v.rule_id == "name[missing]" }.must_equal(2)
      ensure
        File.delete(path)
      end
    end

    it "reports only the syntax-check match on role files a targeted role's syntax check walks" do
      dir = File.tempname("lintrole")
      tasks_dir = File.join(dir, "roles", "myrole", "tasks")
      Dir.mkdir_p(tasks_dir)
      path = File.join(tasks_dir, "main.yml")
      File.write(path, "---\n- krikri_ok:\n- ansible.builtin.debug:\n    msg: hi\n")
      begin
        violations = Runner.new(RuleRegistry.default)
          .run([path], [File.join(dir, "roles", "myrole")])
        violations.map(&.rule_id).must_equal(["syntax-check[unknown-module]"])
        violations.first.path.must_equal(path)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "keeps reporting role files that no syntax check walks" do
      # A sibling of main.yml loads only if main.yml imports it, so
      # upstream's role syntax check never names it - verified against
      # ansible-lint 25.2.1.
      dir = File.tempname("lintrole")
      tasks_dir = File.join(dir, "roles", "myrole", "tasks")
      Dir.mkdir_p(tasks_dir)
      path = File.join(tasks_dir, "extra.yml")
      File.write(path, "---\n- krikri_ok:\n- ansible.builtin.debug:\n    msg: hi\n")
      begin
        violations = Runner.new(RuleRegistry.default)
          .run([path], [File.join(dir, "roles", "myrole")])
        violations.count { |v| v.rule_id == "name[missing]" }.must_equal(2)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "keeps reporting an imported task file outside a role" do
      # Upstream's check names the imported file but its failed-file
      # marking misses imported task files outside a role, so the file
      # (and the playbook importing it) keep reporting - verified
      # against ansible-lint 25.2.1.
      dir = File.tempname("lintimp")
      Dir.mkdir(dir)
      Dir.mkdir(File.join(dir, "tasks"))
      path = File.join(dir, "tasks", "bad.yml")
      File.write(path, "---\n- krikri_ok:\n- ansible.builtin.debug:\n    msg: hi\n")
      play = File.join(dir, "site.yml")
      File.write(play, "---\n- hosts: localhost\n  tasks:\n" \
                        + "    - ansible.builtin.import_tasks: tasks/bad.yml\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([play, path], [dir])
        violations.count { |v| v.rule_id == "name[missing]" && v.path == path }
          .must_equal(2)
        violations.any? { |v| v.rule_id == "name[play]" && v.path == play }
          .must_equal(true)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "reports a play role no search path holds and drops what it loads" do
      # The playbook's own directory is named like the role it lists, so
      # krikri's wider role-file lookup still finds that directory's
      # tasks while ansible's search paths (the playbook's roles/ dir,
      # roles_path, the playbook's dir) hold no `<dir>/kop_probe_role`.
      # ansible aborts the load with "The role 'kop_probe_role' was not
      # found in: ..." at the entry (line 5, column 7 - verified against
      # ansible-lint 25.2.1), which also stops it from walking the
      # playbook's children, so its tasks report nothing.
      dir = PluginSpecHelper.tmp_path("lint_missing_role")
      playbook_dir = File.join(dir, "kop_probe_role")
      FileUtils.mkdir_p(File.join(playbook_dir, "tasks"))
      File.write(File.join(playbook_dir, "tasks", "main.yml"),
        "---\n- ansible.builtin.debug:\n    msg: hi\n")
      path = File.join(playbook_dir, "play.yml")
      File.write(path, "---\n- name: Play\n  hosts: localhost\n  roles:\n" \
                        + "    - role: kop_probe_role\n")
      begin
        violations = Runner.new(RuleRegistry.default).run(Imports.expand([path]), [path])
        violations.size.must_equal(1)
        violation = violations.first
        violation.rule_id.must_equal("syntax-check[specific]")
        violation.path.must_equal(Imports.relative(path))
        violation.line.must_equal(5)
        violation.column.must_equal(7)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "still lints a role a playbook resolves through its roles/ dir" do
      dir = PluginSpecHelper.tmp_path("lint_found_role")
      playbook_dir = File.join(dir, "site")
      role_tasks = File.join(playbook_dir, "roles", "probe_role", "tasks")
      FileUtils.mkdir_p(role_tasks)
      File.write(File.join(role_tasks, "main.yml"),
        "---\n- ansible.builtin.debug:\n    msg: hi\n")
      path = File.join(playbook_dir, "play.yml")
      File.write(path, "---\n- name: Play\n  hosts: localhost\n  roles:\n" \
                        + "    - probe_role\n")
      begin
        violations = Runner.new(RuleRegistry.default).run(Imports.expand([path]), [path])
        violations.map(&.rule_id).must_equal(["name[missing]"])
        violations.first.path.must_equal(Imports.relative(File.join(role_tasks, "main.yml")))
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "Runner against a collection krikri's tables do not know" do
    # The unknown-module rule answers from krikri's OWN baked tables now
    # (a captured collection's file tree), never from an installed
    # collections tree - so a collection the capture never saw stays
    # UNDECIDED (permissive) however the collection env is pointed, and no
    # syntax-check gate fires on it. serial! because the spec pokes ENV.
    serial!

    it "stays permissive for a name outside the captured tables, whatever the collection env says" do
      dir = PluginSpecHelper.tmp_path("lint_uncaptured_collection")
      later = File.join(dir, "later")
      FileUtils.mkdir_p(File.join(dir, "first", "ansible_collections", "testns", "dup"))
      FileUtils.mkdir_p(File.join(later, "ansible_collections", "testns", "dup", "plugins", "modules"))
      File.write(File.join(later, "ansible_collections", "testns", "dup", "plugins", "modules", "shadowed.py"),
        "# fixture module\n")
      path = File.join(dir, "play.yml")
      File.write(path, "---\n- hosts: all\n  tasks:\n" \
                        + "    - testns.dup.shadowed:\n" \
                           + "    - ansible.builtin.debug:\n        msg: hi\n")
      begin
        plain = Runner.new(RuleRegistry.default).run([path]).map(&.rule_id)

        ENV["ANSIBLE_COLLECTIONS_PATH"] = "#{File.join(dir, "first")}:#{later}"
        Krikri::CollectionIndex.reset!
        with_env = Runner.new(RuleRegistry.default).run([path]).map(&.rule_id)

        with_env.must_equal(plain)
        # Undecided means no syntax-check gate: the ordinary rules keep
        # running (the unnamed tasks get name[missing]).
        plain.wont_include("syntax-check[unknown-module]")
        plain.count { |id| id == "name[missing]" }.must_equal(2)
      ensure
        ENV.delete("ANSIBLE_COLLECTIONS_PATH")
        Krikri::CollectionIndex.reset!
      end
    end
  end
end
