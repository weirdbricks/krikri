require "../minitest_helper"
require "file_utils"

# include_role:/import_role:/import_tasks:/include_tasks: argument
# validation at PARSE time - real ansible-core's TaskInclude.check_options
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

# The `~/.ansible/roles` entry of the "was not found in ..." message. Real
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

  it "refuses a non-string *_from value at parse time WITHOUT an Origin block" do
    # The FROM_ARGS raise carries no obj=data in real's source, so its
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

  it "renders the missing import_tasks file the way real's DataLoader error does (no Origin, rc=1 path)" do
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
    ex.render.must_equal(
      "[ERROR]: Unable to retrieve file contents.\n" \
      "Could not find or access '#{resolved}' on the Ansible Controller.\n" \
      "If you are using a module and expect the file to exist on the remote, see the remote_src option: [Errno 2] No such file or directory: '#{resolved}'\n\n")
    ex.render.wont_include("Origin:")
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

  it "reports import_role naming a missing role with real's search-path message and the name value's Origin" do
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
      "the role 'zzznope' was not found in #{File.expand_path(root)}/roles:#{ansible_home}/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles:#{File.expand_path(root)}")
    ex.render.not_nil!.must_include("Origin: #{File.expand_path(path)}:")
  end
end
