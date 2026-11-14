require "file_utils"
require "../minitest_helper"

# Ansible's linear strategy is host-lockstep at the TASK level: an include
# statement expands into its loaded task list for ALL of its hosts first,
# and each included task then runs on every host before the next one
# starts. Running one host's whole include (or whole role) before the next
# host even begins reorders side effects for anything serial:/run_once:/a
# later cross-host task depends on (issue #1240).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_lockstep_play(files : Hash(String, String)) : {Int32, String}
  dir = File.tempname("multi-host-include-lockstep")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\nnode1 ansible_connection=local\n")
  files.each do |name, content|
    path = File.join(dir, name)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  stdout_io = IO::Memory.new
  # -f 1 keeps the per-task host order deterministic (the default forks path
  # prints each host's buffered block as it finishes), which is what the
  # ordering assertions below compare.
  status = Process.run(BINARY, ["-i", "inv.ini", "-f", "1", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

private def assert_output_order(test : Minitest::Test, output : String, markers : Array(String)) : Nil
  cursor = 0
  markers.each do |marker|
    at = output.index(marker, cursor)
    test.flunk("expected #{marker.inspect} after byte #{cursor} in:\n#{output}") unless at
    cursor = at + marker.size
  end
end

# Verified against ansible-core 2.21.5 (the issue's own repro): both
# items' `included:` lines print first, each listing both hosts, and both
# hosts run the first item's included task before either runs the second.
describe "multi-host looped include_tasks ordering" do
  it "runs each included task on every host before the next item's copy" do
    code, output = run_lockstep_play({
      "pb.yml" => <<-YAML,
        - hosts: all
          gather_facts: false
          tasks:
            - name: Include per item
              ansible.builtin.include_tasks: inc.yml
              loop: [a, b]
        YAML
      "inc.yml" => <<-YAML,
        - name: included
          ansible.builtin.debug:
            msg: "in include on {{ inventory_hostname }}"
        YAML
    })

    code.must_equal(0)
    assert_output_order(self, output, [
      "inc.yml for localhost, node1 => (item=a)",
      "inc.yml for localhost, node1 => (item=b)",
      "TASK [included]",
      "in include on localhost",
      "in include on node1",
      "TASK [included]",
      "in include on localhost",
      "in include on node1",
    ])
  end
end

describe "multi-host include_role ordering" do
  it "runs each role task on every host before the next role task" do
    code, output = run_lockstep_play({
      "pb.yml" => <<-YAML,
        - hosts: all
          gather_facts: false
          tasks:
            - name: Include role
              ansible.builtin.include_role:
                name: r
        YAML
      "roles/r/tasks/main.yml" => <<-YAML,
        - name: role task one
          ansible.builtin.debug:
            msg: "one on {{ inventory_hostname }}"
        - name: role task two
          ansible.builtin.debug:
            msg: "two on {{ inventory_hostname }}"
        YAML
    })

    code.must_equal(0)
    assert_output_order(self, output, [
      "included: r for localhost, node1",
      "TASK [r : role task one]",
      "one on localhost",
      "one on node1",
      "TASK [r : role task two]",
      "two on localhost",
      "two on node1",
    ])
  end
end
