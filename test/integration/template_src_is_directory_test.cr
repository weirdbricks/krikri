require "file_utils"
require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Issue #141 (apolloclark.mysql_deploy): a template `src` that is a
# directory fails in ansible with the "Task failed: " crash wrapper and
# Python's [Errno 21] wording, not a krikri-specific "Failed to read
# template file" message.
describe "template with a directory src" do
  it "fails with ansible's read-error wording" do
    dir = PluginSpecHelper.tmp_path("tpl_src_dir")
    srcdir = File.join(dir, "srcdir")
    Dir.mkdir_p(srcdir)
    File.write(File.join(srcdir, "x.txt"), "x")
    dest = File.join(dir, "out.txt")
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: template src is a directory
            ansible.builtin.template:
              src: #{srcdir}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    text = output.to_s
    msg = "An error occurred while trying to read the file '#{srcdir}': [Errno 21] Is a directory: '#{srcdir}'"
    text.must_include("[ERROR]: Task failed: #{msg}\nOrigin: #{playbook}:4:7")
    text.must_include(%("msg": "Task failed: #{msg}"))
    text.wont_include("Failed to read template file")
  end

  # Issue #425 (apolloclark.mysql_deploy): a template src whose value
  # TEMPLATES to the empty string dwims to a directory (the role's
  # templates/ dir, or the role root when there is none) and fails the
  # read with the [Errno 21] wording - real names that path WITHOUT a
  # trailing separator (its loader normpaths every resolved path);
  # krikri used to carry the File.join(dir, "") slash into the message.
  it "dwims an empty templated src to the role's templates dir without a trailing separator" do
    dir = PluginSpecHelper.tmp_path("tpl_src_dir_empty_var")
    role = File.join(dir, "roles", "probe")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    FileUtils.mkdir_p(File.join(role, "defaults"))
    FileUtils.mkdir_p(File.join(role, "templates"))
    File.write(File.join(role, "defaults", "main.yml"), "empty_var: \"\"\n")
    tasks = File.join(role, "tasks", "main.yml")
    File.write(tasks, <<-YAML)
      ---
      - name: empty template src
        ansible.builtin.template:
          src: "{{ empty_var }}"
          dest: #{File.join(dir, "out.txt")}
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - probe
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: dir)

    status.success?.must_equal(false)
    text = output.to_s
    msg = "An error occurred while trying to read the file '#{role}/templates': [Errno 21] Is a directory: '#{role}/templates'"
    text.must_include("[ERROR]: Task failed: #{msg}\nOrigin: #{tasks}:2:3")
    text.must_include(%("msg": "Task failed: #{msg}"))
    text.wont_include("templates/'")
  end

  # Same empty-src dwim in a role WITHOUT a templates/ dir - real falls
  # back to the role root itself (the exact shape apolloclark.mysql_deploy
  # hit live: "Is a directory" naming the bare role path, no slash).
  it "dwims an empty templated src to the role root without a trailing separator when no templates dir exists" do
    dir = PluginSpecHelper.tmp_path("tpl_src_dir_empty_var_root")
    role = File.join(dir, "roles", "probe")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    FileUtils.mkdir_p(File.join(role, "defaults"))
    File.write(File.join(role, "defaults", "main.yml"), "empty_var: \"\"\n")
    tasks = File.join(role, "tasks", "main.yml")
    File.write(tasks, <<-YAML)
      ---
      - name: empty template src
        ansible.builtin.template:
          src: "{{ empty_var }}"
          dest: #{File.join(dir, "out.txt")}
      YAML
    playbook = File.join(dir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - probe
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: dir)

    status.success?.must_equal(false)
    text = output.to_s
    msg = "An error occurred while trying to read the file '#{role}': [Errno 21] Is a directory: '#{role}'"
    text.must_include("[ERROR]: Task failed: #{msg}\nOrigin: #{tasks}:2:3")
    text.must_include(%("msg": "Task failed: #{msg}"))
    text.wont_include("#{role}/'")
  end
end
