require "../minitest_helper"
require "file_utils"
require "../../src/krikri/playbook_parser"

# include_role:/import_role:/import_tasks:/include_tasks: argument
# validation at PARSE time - ansible-core's TaskInclude.check_options
# and IncludeRole.load run while the playbook is loading, so every bad
# argument aborts the whole run with an "[ERROR]: ..." block (plus the
# task's Origin block, except the FROM_ARGS raise) and rc=4 before any
# play banner. Byte shapes live-verified against ansible-core 2.19.11.
private def write_playbook(root : String, tasks_yaml : String) : String
  FileUtils.rm_rf(root) if Dir.exists?(root)
  Dir.mkdir_p(root)
  path = File.join(root, "site.yml")
  body = <<-YAML
    - name: play
      hosts: all
      gather_facts: false
      tasks:
    YAML
  # Re-indent the task fragment under tasks: (interpolation inside a
  # heredoc would not strip the fragment's continuation lines).
  indented = tasks_yaml.lines.map { |line| line.empty? ? line : "    " + line }.join("\n") + "\n"
  File.write(path, body + "\n" + indented)
  path
end

# The `~/.ansible/roles` entry of the "was not found in ..." message.
# ansible resolves `~` through `os.path.expanduser`, which reads `$HOME`
# first and only falls back to the passwd entry, so the expectation has to
# be built the same way - `Path.home` alone disagrees on any host where the
# two differ (the GitHub CI image runs as a uid whose passwd home is /root
# while `HOME=/github/home`).
private def ansible_home : String
  ENV["HOME"]? || Path.home.to_s
end

describe "PlaybookParser include directive argument validation" do
  it "refuses include_role without name at parse time, with the task's Origin" do
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_no_name"), <<-YAML)
        - name: t1
          ansible.builtin.include_role: {}
      YAML

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal("'name' is a required field for ansible.builtin.include_role.")
    ex.render.must_include("Origin: #{File.expand_path(path)}:")
    ex.render.must_match(/\A\[ERROR\]: 'name' is a required field for ansible\.builtin\.include_role\.\n/)
  end

  it "refuses unknown include_role options at parse time, in playbook key order" do
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_bad_opts"), <<-YAML)
        - name: t1
          ansible.builtin.include_role:
            name: whatever
            handler_sfrom: gggmgo
            vars_frmo: ypcyoz
      YAML

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal(
      "Invalid options for ansible.builtin.include_role: handler_sfrom,vars_frmo")
    ex.render.must_include("Origin: ")
  end

  it "refuses a non-dict apply on include_role at parse time" do
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_apply_str"), <<-YAML)
        - name: t1
          ansible.builtin.include_role:
            apply: qzxgsg
            name: whatever
      YAML

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal(
      "Expected a dict for apply but got <class 'ansible.module_utils._internal._datatag._AnsibleTaggedStr'> instead")
  end

  it "accepts rescuable: on include_role (ansible-core's IncludeRole OTHER_ARGS, issue #923)" do
    # Live-verified against ansible-core 2.21.6: `include_role:
    # {rescuable: true}` runs the role; refusing it as an unknown option
    # (the pre-fix behavior) aborts the whole playbook at load instead.
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_rescuable_ok"), <<-YAML)
        - name: t1
          ansible.builtin.include_role:
            name: whatever
            rescuable: true
      YAML

    Krikri::PlaybookParser.parse(File.expand_path(path))
  end

  it "refuses a truthy rescuable on import_role at parse time, with Origin" do
    # Real's `if resc_attr and ir.action not in _ACTION_INCLUDE_ROLE`
    # carries obj=data, so the block renders WITH an Origin (live-
    # verified vs 2.21.6).
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_import_rescuable"), <<-YAML)
        - name: t1
          ansible.builtin.import_role:
            name: whatever
            rescuable: true
      YAML

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal("Invalid options for ansible.builtin.import_role: rescuable")
    ex.render.must_include("Origin: #{File.expand_path(path)}:")
  end

  it "accepts a falsy rescuable on import_role (real gates the refusal on Python truthiness)" do
    # Live-verified vs 2.21.6: `import_role: {rescuable: false}` parses
    # and runs - only a truthy rescuable is refused there. The role has
    # to exist: a static import resolves (and refuses a missing) role at
    # parse time regardless of rescuable.
    root = PluginSpecHelper.tmp_path("incdir_import_rescuable_false")
    path = write_playbook(root, <<-YAML)
        - name: t1
          ansible.builtin.import_role:
            name: whatever
            rescuable: false
      YAML
    Dir.mkdir_p(File.join(root, "roles", "whatever", "tasks"))
    File.write(File.join(root, "roles", "whatever", "tasks", "main.yml"), "- debug: msg=hi\n")

    Krikri::PlaybookParser.parse(File.expand_path(path))
  end

  it "orders the rescuable bool-keyword conversion last (after rolespec_validate)" do
    # Live-verified vs 2.21.6: a task with both rolespec_validate and
    # rescuable unconvertible reports `rolespec_validate` - rescuable is
    # declared last on IncludeRole.
    args = Hash(YAML::Any, YAML::Any).new
    args[YAML::Any.new("rolespec_validate")] = YAML::Any.new("snhvdg")
    args[YAML::Any.new("rescuable")] = YAML::Any.new("snhvdg")
    Krikri::RoleBoolKeywords.failure(args).try(&.keyword).must_equal("rolespec_validate")

    args = Hash(YAML::Any, YAML::Any).new
    args[YAML::Any.new("rescuable")] = YAML::Any.new("snhvdg")
    failure = Krikri::RoleBoolKeywords.failure(args)
    failure.try(&.keyword).must_equal("rescuable")
    failure.try(&.value_repr).must_equal("'snhvdg'")
    failure.try(&.brief).must_equal(
      "Error processing keyword 'rescuable': The value 'snhvdg' could not be converted to 'bool'.")
  end

  it "refuses a non-string *_from value at parse time WITHOUT an Origin block" do
    # The FROM_ARGS raise carries no obj=data in Ansible's source, so its
    # block is just the [ERROR] line (live-verified vs 2.19.11).
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_from_int"), <<-YAML)
        - name: t1
          ansible.builtin.include_role:
            name: whatever
            tasks_from: 5
      YAML

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal(
      "Expected a string for tasks_from but got <class 'ansible.module_utils._internal._datatag._AnsibleTaggedInt'> instead")
    ex.render.must_equal("[ERROR]: #{ex.message}\n")
    ex.render.wont_include("Origin:")
  end

  it "refuses import_tasks with no file at all (null, empty string, empty mapping) at parse time" do
    shapes = {
      "null"           => "      - ansible.builtin.import_tasks:\n",
      "empty-string"   => "      - ansible.builtin.import_tasks: ''\n",
      "empty-mapping"  => "      - ansible.builtin.import_tasks: {}\n",
      "empty-file-key" => "      - ansible.builtin.import_tasks:\n          file: ''\n",
    }
    shapes.each do |label, task_yaml|
      root = PluginSpecHelper.tmp_path("incdir_no_file_#{label}")
      path = write_playbook(root, task_yaml)

      ex = assert_raises(Krikri::IncludeDirectiveError) do
        Krikri::PlaybookParser.parse(File.expand_path(path))
      end
      ex.message.to_s.must_equal("No file specified for ansible.builtin.import_tasks")
      ex.render.must_include("Origin: ")
    end
  end

  it "refuses unknown import_tasks options at parse time" do
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_import_freeform"), <<-YAML)
        - name: t1
          ansible.builtin.import_tasks:
            free-form: huvdzn
      YAML

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal("Invalid options for ansible.builtin.import_tasks: free-form")
  end

  it "refuses apply: on import_tasks even when the file exists" do
    root = PluginSpecHelper.tmp_path("incdir_import_apply")
    path = write_playbook(root, <<-YAML)
        - name: t1
          ansible.builtin.import_tasks:
            apply: x
            file: real.yml
      YAML
    File.write(File.join(root, "real.yml"), "- debug: msg=hi\n")

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal("Invalid options for ansible.builtin.import_tasks: apply")
  end

  it "refuses include_tasks with no file path at parse time" do
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_inc_no_file"), <<-YAML)
        - name: t1
          ansible.builtin.include_tasks: {}
      YAML

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal("No file specified for ansible.builtin.include_tasks")
  end

  it "refuses a non-string free-form import_tasks value at parse time" do
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_import_int"), <<-YAML)
        - name: t1
          ansible.builtin.import_tasks: 5
      YAML

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal(
      "unexpected parameter type in action: <class 'ansible.module_utils._internal._datatag._AnsibleTaggedInt'>")
  end

  it "renders the missing import_tasks file the way Ansible's DataLoader error does (no Origin, rc=1 path)" do
    root = PluginSpecHelper.tmp_path("incdir_import_missing")
    path = write_playbook(root, <<-YAML)
        - name: t1
          ansible.builtin.import_tasks:
            file: bhwidi
      YAML

    ex = assert_raises(Krikri::StaticImportMissingFileError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    resolved = File.expand_path("bhwidi", root)
    # ansible-core 2.21 folds the chained OSError and the AnsibleFileNotFound
    # help text into one "[ERROR]:" line: the head's trailing period dropped,
    # the cause joined with ": ", the hint appended after a space.
    ex.render.must_equal(
      "[ERROR]: Unable to retrieve file contents. Could not find or access '#{resolved}' on the Ansible Controller: " \
      "[Errno 2] No such file or directory: '#{resolved}' " \
      "If you are using a module and expect the file to exist on the remote, see the remote_src option.\n")
    ex.render.wont_include("Origin:")
  end

  it "counterfeits Ansible's uncaught path_dwim TypeError crash for a non-string import_tasks file value" do
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_import_int_file"), <<-YAML)
        - name: t1
          ansible.builtin.import_tasks:
            file: 46
      YAML

    ex = assert_raises(Krikri::StaticImportNonStringFileError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    # Real ansible-playbook (2.21.6) dies here with an uncaught Python
    # TypeError - its own path_dwim runs len() over the _AnsibleTaggedInt -
    # printing the [ERROR] line plus both tracebacks, rc=250, before any
    # play output, whatever file the stringified value would have resolved
    # to (live-verified in a fresh kpg container, issues #934/#945/#1122).
    # Pinned byte for byte against that container's stderr.
    pkg = "/usr/local/lib/python3.13/dist-packages/ansible"
    ex.render.must_equal(([
      "[ERROR]: Unexpected Exception, this is probably a bug: object of type '_AnsibleTaggedInt' has no len()",
      "",
      "Traceback (most recent call last):",
      "  File \"#{pkg}/cli/__init__.py\", line 663, in cli_executor",
      "    exit_code = cli.run()",
      "  File \"#{pkg}/cli/playbook.py\", line 152, in run",
      "    results = pbex.run()",
      "  File \"#{pkg}/executor/playbook_executor.py\", line 100, in run",
      "    pb = Playbook.load(playbook_path, variable_manager=self._variable_manager, loader=self._loader)",
      "  File \"#{pkg}/playbook/__init__.py\", line 50, in load",
      "    pb._load_playbook_data(file_name=file_name, variable_manager=variable_manager)",
      " " * 4 + "~" * 22 + "^" * 56,
      "  File \"#{pkg}/playbook/__init__.py\", line 105, in _load_playbook_data",
      "    entry_obj = Play.load(entry, variable_manager=variable_manager, loader=self._loader, vars=vars)",
      "  File \"#{pkg}/playbook/play.py\", line 153, in load",
      "    return p.load_data(data, variable_manager=variable_manager, loader=loader)",
      " " * 11 + "~" * 11 + "^" * 56,
      "  File \"#{pkg}/playbook/base.py\", line 178, in load_data",
      "    setattr(self, name, method(name, ds[name]))",
      " " * 24 + "~" * 6 + "^" * 16,
      "  File \"#{pkg}/playbook/play.py\", line 189, in _load_tasks",
      "    return self._load(attr, ds)",
      " " * 11 + "~" * 10 + "^" * 10,
      "  File \"#{pkg}/playbook/play.py\", line 184, in _load",
      "    return load_list_of_blocks(ds=ds, play=self, variable_manager=self._variable_manager, loader=self._loader)",
      "  File \"#{pkg}/playbook/helpers.py\", line 67, in load_list_of_blocks",
      "    Block.load(",
      " " * 4 + "~" * 10 + "^" * 1,
      "        b,",
      " " * 8 + "^" * 2,
      "    ...<6 lines>...",
      "        loader=loader,",
      " " * 8 + "^" * 14,
      "    )",
      " " * 4 + "^" * 1,
      "  File \"#{pkg}/playbook/block.py\", line 88, in load",
      "    return b.load_data(data, variable_manager=variable_manager, loader=loader)",
      " " * 11 + "~" * 11 + "^" * 56,
      "  File \"#{pkg}/playbook/base.py\", line 178, in load_data",
      "    setattr(self, name, method(name, ds[name]))",
      " " * 24 + "~" * 6 + "^" * 16,
      "  File \"#{pkg}/playbook/block.py\", line 130, in _load_block",
      "    return self._load(attr, ds)",
      " " * 11 + "~" * 10 + "^" * 10,
      "  File \"#{pkg}/playbook/block.py\", line 116, in _load",
      "    return load_list_of_tasks(",
      "        ds,",
      "    ...<6 lines>...",
      "        use_handlers=self._use_handlers,",
      "    )",
      "  File \"#{pkg}/playbook/helpers.py\", line 207, in load_list_of_tasks",
      "    include_file = loader.path_dwim(include_target)",
      "  File \"#{pkg}/parsing/dataloader.py\", line 237, in path_dwim",
      "    given = unquote(given)",
      "  File \"#{pkg}/parsing/quoting.py\", line 27, in unquote",
      "    if is_quoted(data):",
      " " * 7 + "~" * 9 + "^" * 6,
      "  File \"#{pkg}/parsing/quoting.py\", line 22, in is_quoted",
      "    return len(data) > 1 and data[0] == data[-1] and data[0] in ('\"', \"'\") and data[-2] != '\\\\'",
      " " * 11 + "~" * 3 + "^" * 6,
      "TypeError: object of type '_AnsibleTaggedInt' has no len()",
      "",
      "The above exception was the direct cause of the following exception:",
      "",
      "Traceback (most recent call last):",
      "  File \"#{pkg}/cli/__init__.py\", line 672, in cli_executor",
      "    raise AnsibleError(\"Unexpected Exception, this is probably a bug.\") from ex",
      "ansible.errors.AnsibleError: Unexpected Exception, this is probably a bug: object of type '_AnsibleTaggedInt' has no len()",
    ]).join("\n") + "\n\n")
  end

  it "swaps the play.py frame for _load_handlers when the import is a handler" do
    pkg = "/usr/local/lib/python3.13/dist-packages/ansible"
    tasks_path = write_playbook(PluginSpecHelper.tmp_path("incdir_import_int_handler_tasks"), <<-YAML)
        - name: t1
          ansible.builtin.import_tasks:
            file: 46
      YAML
    tasks_ex = assert_raises(Krikri::StaticImportNonStringFileError) do
      Krikri::PlaybookParser.parse(File.expand_path(tasks_path))
    end

    handler_root = PluginSpecHelper.tmp_path("incdir_import_int_handler")
    FileUtils.rm_rf(handler_root) if Dir.exists?(handler_root)
    Dir.mkdir_p(handler_root)
    handler_path = File.join(handler_root, "site.yml")
    File.write(handler_path, <<-YAML)
        - name: play
          hosts: all
          gather_facts: false
          handlers:
            - name: h1
              ansible.builtin.import_tasks:
                file: 46
      YAML
    handler_ex = assert_raises(Krikri::StaticImportNonStringFileError) do
      Krikri::PlaybookParser.parse(File.expand_path(handler_path))
    end
    # Real loads a play's handlers through play.py's _load_handlers, whose
    # single frame (with its own call line and anchor) replaces the tasks
    # path's _load_tasks + _load pair (live-verified vs 2.21.6).
    handler_ex.render.must_equal(tasks_ex.render.sub(
      "  File \"#{pkg}/playbook/play.py\", line 189, in _load_tasks\n" \
      "    return self._load(attr, ds)\n" +
      (" " * 11 + "~" * 10 + "^" * 10 + "\n") +
      "  File \"#{pkg}/playbook/play.py\", line 184, in _load\n" \
      "    return load_list_of_blocks(ds=ds, play=self, variable_manager=self._variable_manager, loader=self._loader)\n",
      "  File \"#{pkg}/playbook/play.py\", line 205, in _load_handlers\n" \
      "    load_list_of_blocks(ds=ds, play=self, use_handlers=True, variable_manager=self._variable_manager, loader=self._loader),\n" +
      (" " * 4 + "~" * 19 + "^" * 99 + "\n")))
  end

  it "names the value's tagged Python type in the crash (float/bool)" do
    {"4.6" => "_AnsibleTaggedFloat", "true" => "bool"}.each do |literal, type_name|
      path = write_playbook(PluginSpecHelper.tmp_path("incdir_import_int_type_#{type_name}"), <<-YAML)
          - name: t1
            ansible.builtin.import_tasks:
              file: #{literal}
        YAML
      ex = assert_raises(Krikri::StaticImportNonStringFileError) do
        Krikri::PlaybookParser.parse(File.expand_path(path))
      end
      ex.render.includes?("TypeError: object of type '#{type_name}' has no len()").must_equal(true)
    end
  end

  it "keeps a non-string include_tasks file literal native for the run-time crash check" do
    path = write_playbook(PluginSpecHelper.tmp_path("incdir_include_int_file"), <<-YAML)
        - name: t1
          ansible.builtin.include_tasks:
            file: 32
      YAML

    # Unlike the static import_tasks: (which dies at playbook-load), a
    # non-string include_tasks: file: passes load - real's crash happens
    # in the linear strategy's include-result processing, after the TASK
    # banner. Parse must therefore succeed and keep the literal's native
    # type for the executor's run-time check to key on (issue #1125).
    play = Krikri::PlaybookParser.parse(File.expand_path(path)).plays[0]
    play.tasks[0].include_file_native.try(&.raw).must_equal(32)
  end

  it "counterfeits Ansible's uncaught path_dwim TypeError crash for a non-string include_tasks file value" do
    pkg = "/usr/local/lib/python3.13/dist-packages/ansible"
    # Real (2.21.6) gets past the TASK banner, then its linear strategy's
    # include-result processing feeds the _AnsibleTaggedInt to
    # path_dwim, whose len() TypeError escapes uncaught: [ERROR] line
    # plus both tracebacks on STDERR, rc=250, no recap and no per-host
    # result line - whatever file the stringified value would have
    # resolved to (live-verified in a fresh kpg container, issue #1125).
    # Pinned byte for byte against that container's stderr. Same
    # path_dwim tail as the static import's crash, but the strategy-side
    # stack above it differs.
    Krikri::PlaybookParser.include_tasks_non_string_file_crash_render("_AnsibleTaggedInt").must_equal(([
      "[ERROR]: Unexpected Exception, this is probably a bug: object of type '_AnsibleTaggedInt' has no len()",
      "",
      "Traceback (most recent call last):",
      "  File \"#{pkg}/cli/__init__.py\", line 663, in cli_executor",
      "    exit_code = cli.run()",
      "  File \"#{pkg}/cli/playbook.py\", line 152, in run",
      "    results = pbex.run()",
      "  File \"#{pkg}/executor/playbook_executor.py\", line 179, in run",
      "    result = self._tqm.run(play=play)",
      "  File \"#{pkg}/executor/task_queue_manager.py\", line 403, in run",
      "    play_return = strategy.run(iterator, play_context)",
      "  File \"#{pkg}/plugins/strategy/linear.py\", line 241, in run",
      "    included_files = IncludedFile.process_include_results(",
      "        results,",
      "    ...<2 lines>...",
      "        variable_manager=self._variable_manager",
      "    )",
      "  File \"#{pkg}/playbook/included_file.py\", line 196, in process_include_results",
      "    include_file = loader.path_dwim(include_utr.include_file)",
      "  File \"#{pkg}/parsing/dataloader.py\", line 237, in path_dwim",
      "    given = unquote(given)",
      "  File \"#{pkg}/parsing/quoting.py\", line 27, in unquote",
      "    if is_quoted(data):",
      " " * 7 + "~" * 9 + "^" * 6,
      "  File \"#{pkg}/parsing/quoting.py\", line 22, in is_quoted",
      "    return len(data) > 1 and data[0] == data[-1] and data[0] in ('\"', \"'\") and data[-2] != '\\\\'",
      " " * 11 + "~" * 3 + "^" * 6,
      "TypeError: object of type '_AnsibleTaggedInt' has no len()",
      "",
      "The above exception was the direct cause of the following exception:",
      "",
      "Traceback (most recent call last):",
      "  File \"#{pkg}/cli/__init__.py\", line 672, in cli_executor",
      "    raise AnsibleError(\"Unexpected Exception, this is probably a bug.\") from ex",
      "ansible.errors.AnsibleError: Unexpected Exception, this is probably a bug: object of type '_AnsibleTaggedInt' has no len()",
    ]).join("\n") + "\n\n")
  end

  it "keeps the missing-file render for a block-nested import, whose real traceback frames differ" do
    block_path = write_playbook(PluginSpecHelper.tmp_path("incdir_import_int_block"), <<-YAML)
        - block:
            - ansible.builtin.import_tasks:
                file: 46
      YAML
    # A block-nested import loads through an extra helpers.py Block.load
    # frame whose traceback this render does not counterfeit; real still
    # crashes there, but the stringified missing-file render is kept.
    assert_raises(Krikri::StaticImportMissingFileError) do
      Krikri::PlaybookParser.parse(File.expand_path(block_path))
    end
  end

  it "keeps the missing-file render for a role task import, whose real traceback frames differ" do
    root = PluginSpecHelper.tmp_path("incdir_import_int_role")
    tasks_dir = File.join(root, "roles", "r", "tasks")
    Dir.mkdir_p(tasks_dir)
    File.write(File.join(tasks_dir, "main.yml"), "- ansible.builtin.import_tasks:\n    file: 46\n")
    role_path = File.join(root, "site.yml")
    File.write(role_path, <<-YAML)
        - name: play
          hosts: all
          gather_facts: false
          roles:
            - r
      YAML
    # A role's tasks load through a role-aware path_dwim_relative frame
    # whose traceback this render does not counterfeit; real still crashes
    # there, but the stringified missing-file render is kept.
    assert_raises(Krikri::StaticImportMissingFileError) do
      Krikri::PlaybookParser.parse(File.expand_path(role_path))
    end
  end

  it "reports a missing role include against the playbook dir, not the role tasks dir" do
    root = File.expand_path(PluginSpecHelper.tmp_path("incdir_role_missing_path"))
    tasks_dir = File.join(root, "roles", "r", "tasks")
    Dir.mkdir_p(tasks_dir)
    Krikri::PlaybookParser.resolve_include_path("prepare-Rocky.yml", tasks_dir, root)
      .must_equal(File.join(root, "prepare-Rocky.yml"))
  end

  it "validates import_role arguments BEFORE the static role-existence check" do
    root = PluginSpecHelper.tmp_path("incdir_import_role_order")
    # The role DOES exist here - the bad option is still what aborts.
    Dir.mkdir_p(File.join(root, "roles", "testrole", "tasks"))
    File.write(File.join(root, "roles", "testrole", "tasks", "main.yml"), "- debug: msg=hi\n")
    path = write_playbook(root, <<-YAML)
        - name: t1
          ansible.builtin.import_role:
            name: testrole
            bogus: 1
      YAML

    ex = assert_raises(Krikri::IncludeDirectiveError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal("Invalid options for ansible.builtin.import_role: bogus")
  end

  it "reports import_role naming a missing role with Ansible's search-path message and the name value's Origin" do
    root = PluginSpecHelper.tmp_path("incdir_import_role_missing")
    path = write_playbook(root, <<-YAML)
        - name: t1
          ansible.builtin.import_role:
            name: zzznope
      YAML

    ex = assert_raises(Krikri::RoleNotFoundError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal(
      "The role 'zzznope' was not found in: #{File.expand_path(root)}/roles:#{ansible_home}/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles:#{File.expand_path(root)}")
    ex.render.as(String).must_include("Origin: #{File.expand_path(path)}:")
  end
end
