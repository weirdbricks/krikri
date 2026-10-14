require "../minitest_helper"

# ansible-playbook refuses at load time (rc=4, on STDERR) a role task
# file whose unquoted template parses as a collection used AS a mapping
# key (`owner: {{ x }}`), with the same Origin block as every other YAML
# error - krikri used to parse such a file fine and only fail later at
# the task header with an unrelated message.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "unquoted template as a mapping value (template_quoting_error_test.cr)" do
  it "refuses the role's task file at load time like Ansible" do
    role = PluginSpecHelper.tmp_path("roles", "quoting_bad")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    tasks = File.join(role, "tasks", "main.yml")
    File.write(tasks, <<-YAML)
      - name: Configure
        template:
          src: x.j2
          dest: /home/{{ user }}/.cfg
          owner: {{ user }}
      YAML

    playbook = PluginSpecHelper.tmp_path("pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - quoting_bad
      YAML

    stdout_io = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook],
      output: stdout_io, error: stdout_io, chdir: role)
    output = stdout_io.to_s.gsub(File.expand_path(tasks), "TASKS")

    status.exit_code.must_equal(4)
    output.must_include("[ERROR]: YAML parsing failed: This may be an issue with missing quotes around a template block.")
    output.must_include("Origin: TASKS:5:12")
    output.must_include("    owner: {{ user }}")
    output.must_include("Should be:")
  end
end
