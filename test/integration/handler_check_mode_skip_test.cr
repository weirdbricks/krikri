require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook, since the bug lives in
# the controller-side handler dispatch (a handler's skipped module result
# never reaching any display path), not in anything a unit spec against a
# single method can exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# A one-role playbook whose sole handler is the given YAML task body,
# notified from a task that always reports changed.
private def handler_skip_playbook(handler_body : String) : String
  src_dir = File.tempname("handler-skip-display")
  Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
  Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "handlers"))
  File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
    - name: trigger it
      copy:
        content: "x\\n"
        dest: "{{ playbook_dir }}/artifact.txt"
      notify: restart nfs
    YAML
  File.write(File.join(src_dir, "roles", "myrole", "handlers", "main.yml"), handler_body)
  File.write(File.join(src_dir, "pb.yml"), <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      roles:
        - myrole
    YAML
  src_dir
end

private CHECK_MODE_HANDLER = <<-YAML
  - name: restart nfs
    ansible.builtin.command: exportfs-va
  YAML

describe "a handler whose module skips itself" do
  it "prints the same skipping: line a regular task gets under --check" do
    # Found benchmarking alexrmarques.nfs_server (issue #1399): its
    # "Restart NFS CentOS" handler is `command: exportfs -va`, so under
    # --check real ansible prints "skipping:" under the RUNNING HANDLER
    # banner. This engine's handler path displayed nothing at all - it
    # booked skipped=1 in the recap and left an empty banner behind, so
    # the recap counters disagreed with the visible output.
    src_dir = handler_skip_playbook(CHECK_MODE_HANDLER)
    output = IO::Memory.new
    status = Process.run(BINARY, ["--check", "-i", INVENTORY, File.join(src_dir, "pb.yml")],
      output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_match(/RUNNING HANDLER \[myrole : restart nfs\] \*+\nskipping: \[localhost\]\n/)
    output.to_s.must_match(/skipped=1/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "adds the module result dump at -v, like real ansible" do
    src_dir = handler_skip_playbook(CHECK_MODE_HANDLER)
    output = IO::Memory.new
    status = Process.run(BINARY, ["--check", "-v", "-i", INVENTORY, File.join(src_dir, "pb.yml")],
      output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include(%(skipping: [localhost] => {"changed": false, "cmd": ["exportfs-va"]))
    output.to_s.must_include(%("msg": "Command would have run if not in check mode"))
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "prints one item line per loop iteration plus the aggregate line" do
    src_dir = handler_skip_playbook(<<-YAML)
      - name: restart nfs
        ansible.builtin.command: exportfs-va
        loop:
          - a
          - b
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["--check", "-i", INVENTORY, File.join(src_dir, "pb.yml")],
      output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("skipping: [localhost] => (item=a)")
    output.to_s.must_include("skipping: [localhost] => (item=b)")
    # The trailing all-items-skipped line real prints after the items.
    output.to_s.must_match(/skipping: \[localhost\] => \(item=b\) *\nskipping: \[localhost\]\n/)
    output.to_s.must_match(/skipped=1/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "prints skipping: for an action plugin that skips itself (debug: verbosity:)" do
    # The action-plugin dispatch returns its result before the module
    # dispatch, so this shape needs its own display site.
    src_dir = handler_skip_playbook(<<-YAML)
      - name: restart nfs
        ansible.builtin.debug:
          msg: handler verbosity probe
          verbosity: 2
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, File.join(src_dir, "pb.yml")],
      output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_match(/RUNNING HANDLER \[myrole : restart nfs\] \*+\nskipping: \[localhost\]\n/)
    output.to_s.wont_include("handler verbosity probe")
    output.to_s.must_match(/skipped=1/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
