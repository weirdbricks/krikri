require "file_utils"
require "../minitest_helper"

# Runs the compiled binary against a real playbook, since this bug is
# specifically about TaskExecutor#run_include_tasks_once's file-parsing
# rescue path, not reachable from a unit spec without constructing a
# whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

describe "include_tasks: targeting a comment-only (blank) tasks file" do
  it "runs zero tasks instead of failing the whole run" do
    # Real bug found benchmarking ansistrano.deploy (round826): its
    # tasks/main.yml does `include_tasks: "{{ ansistrano_before_setup_
    # tasks_file | default('empty.yml') }}"` at 10 different hook
    # points, all defaulting to the same deliberately-empty tasks/
    # empty.yml (a comment-only no-op file the role itself ships for
    # exactly this "no custom hook" case). YAML.parse returns a bare
    # `nil` document for comment-only content, not an empty array -
    # this engine's `unless yaml.as_a?` check (written for a genuinely
    # malformed file) treated `nil` the same way, failing the whole
    # task ("Included tasks file must be a YAML list") instead of
    # running zero tasks, matching Ansible.
    dir = File.tempname("include-tasks-empty-file")
    Dir.mkdir_p(dir)

    File.write(File.join(dir, "empty.yml"), "# intentionally empty\n")
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: before hook
            ansible.builtin.include_tasks: empty.yml
          - name: real task
            ansible.builtin.debug:
              msg: after include
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, File.join(dir, "site.yml")], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("after include")
    output.to_s.wont_include("must be a YAML list")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # ansible-core 2.19.11: v2_playbook_on_include fires for a zero-task
  # file just like for any other include (`included: <path> for <hosts>`
  # under the TASK banner), which krikri used to swallow entirely on this
  # path - the include registered, ran zero tasks, but printed nothing
  # (pgvillage.linux's shipped-empty hook targets, issue #308).
  it "prints the included: line for a zero-task target under the task banner" do
    dir = File.tempname("include-tasks-empty-included-line")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\nnode1 ansible_connection=local\n")
    File.write(File.join(dir, "empty.yml"), "---\n")
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: before hook
            ansible.builtin.include_tasks: empty.yml
          - name: real task
            ansible.builtin.debug:
              msg: after include
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(dir, "inv.ini"), File.join(dir, "site.yml")], output: output, error: output)
    status.success?.must_equal(true)
    output.to_s.must_include("included: #{File.join(dir, "empty.yml")} for localhost, node1")
    output.to_s.wont_include("must be a YAML list")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # The looped path registers every iteration's include before any of
  # them runs - real ansible prints each iteration's
  # `included: ... for <host> => (item=...)` even when the file has no
  # tasks at all, and each iteration still counts one ok.
  it "prints a per-item included line for a looped comment-only target" do
    dir = File.tempname("include-tasks-empty-looped-line")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
    File.write(File.join(dir, "empty.yml"), "# just a comment\n")
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: looped hook
            ansible.builtin.include_tasks: empty.yml
            loop:
              - alpha
              - beta
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(dir, "inv.ini"), File.join(dir, "site.yml")], output: output, error: output)
    status.success?.must_equal(true)
    output.to_s.must_include("included: #{File.join(dir, "empty.yml")} for localhost => (item=alpha)")
    output.to_s.must_include("included: #{File.join(dir, "empty.yml")} for localhost => (item=beta)")
    output.to_s.wont_include("must be a YAML list")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
