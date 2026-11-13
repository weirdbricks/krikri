require "../minitest_helper"
require "file_utils"

# Regression spec for issue #209: real ansible templates the become_user:
# keyword before it finalizes any module arg, so a task whose become_user
# AND a module arg both reference undefined variables fails with the keyword
# error ("Error processing keyword 'become_user': 'ibm_user' is undefined"),
# never the module's "Finalization of task args" error. The keyword's own
# chain then points at the variable definition that failed.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "an undefined become_user: wins over an undefined module arg" do
  it "reports the become_user keyword error for a command with an undefined arg" do
    root = File.tempname("become-user-keyword-order")
    Dir.mkdir_p(root)

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: list installed packages
            become: true
            become_user: "{{ ihs_user }}"
            command: "{{ iim_path }}/tools/imcl listInstalledPackages"
        vars:
          ihs_user: "{{ ibm_user }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(false, output.to_s)
    output_text = output.to_s
    output_text.includes?("Task failed: Error processing keyword 'become_user': 'ibm_user' is undefined").must_equal(true, output_text)
    output_text.includes?("Error processing keyword 'become_user'.").must_equal(true, output_text)
    output_text.includes?("'iim_path' is undefined").must_equal(false, output_text)
    output_text.includes?("Finalization of task args").must_equal(false, output_text)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Issue #1213 (Alex2357.enable-vino): the failing become_user: is not
  # written on the task at all - it lives on the import_tasks: line that
  # statically inlined it, in ANOTHER file. Real still prints its
  # two-segment chain, with the "caused by" Origin at that import line's
  # become_user: VALUE token; krikri used to find no such line in the
  # inlined task's own file and collapse the two segments into one.
  it "labels an inherited import_tasks: become_user: with the importing line" do
    root = PluginSpecHelper.tmp_path("become-user-import-origin")
    inc_dir = File.join(root, "inc")
    Dir.mkdir_p(inc_dir)
    child_file = File.join(inc_dir, "tasks.yml")
    File.write(child_file, <<-YAML)
      ---
      - name: vino enable remote access.
        debug:
          msg: hi
      YAML
    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - import_tasks: inc/tasks.yml
            become: true
            become_user: "{{ vino_user }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: root)

    text = output.to_s
    status.success?.must_equal(false, text)
    text.must_include("[ERROR]: Task failed: Error processing keyword 'become_user': 'vino_user' is undefined")
    # first segment: the inlined task's own mapping, in ITS file
    text.must_include("Task failed.\nOrigin: #{child_file}:2:3")
    # second segment: the importing file's become_user: VALUE token
    text.must_include("<<< caused by >>>\n\nError processing keyword 'become_user': 'vino_user' is undefined\nOrigin: #{playbook}:7:20")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Error processing keyword 'become_user': 'vino_user' is undefined\"}")
  ensure
    FileUtils.rm_rf(root) if root
  end

  # The flip side of the inheritance above: a task that writes its OWN
  # become_user: keeps its own file's token as the chain's Origin even
  # when the import_tasks: line it came from also wrote one.
  it "keeps a task's own become_user: Origin when its import also sets one" do
    root = PluginSpecHelper.tmp_path("become-user-import-own-origin")
    inc_dir = File.join(root, "inc")
    Dir.mkdir_p(inc_dir)
    child_file = File.join(inc_dir, "tasks.yml")
    File.write(child_file, <<-YAML)
      ---
      - name: own keyword
        debug:
          msg: hi
        become_user: "{{ own_user }}"
      YAML
    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - import_tasks: inc/tasks.yml
            become: true
            become_user: "{{ import_user }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: root)

    text = output.to_s
    status.success?.must_equal(false, text)
    text.must_include("Error processing keyword 'become_user': 'own_user' is undefined")
    text.must_include("Origin: #{child_file}:5:16")
    text.wont_include("'import_user' is undefined")
  ensure
    FileUtils.rm_rf(root) if root
  end
end
