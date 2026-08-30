require "file_utils"
require "../spec_helper"

# --syntax-check and --list-tasks. The expected output below is the
# VERBATIM output of a real ansible-core 2.19.4 run of the same playbook
# (tabs included), not a reconstruction - these two modes are routinely
# machine-read in CI, so the exact shape matters.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private PLAYBOOK = <<-YAML
  - name: First play
    hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: plain task
        ansible.builtin.debug: {msg: "A"}
      - name: tagged task
        ansible.builtin.debug: {msg: "B"}
        tags: [alpha, beta]
      - name: a block
        tags: [outer]
        block:
          - name: inner task
            ansible.builtin.debug: {msg: "C"}
            tags: [inner]
        always:
          - name: always inner
            ansible.builtin.debug: {msg: "D"}
  - name: Second play
    hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: second play task
        ansible.builtin.debug: {msg: "E"}
  YAML

private def run_with(args : Array(String), yaml : String = PLAYBOOK)
  playbook = File.tempname("list-tasks", ".yml")
  File.write(playbook, yaml)
  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY] + args + [playbook],
    output: stdout_io, error: stdout_io)
  {status, stdout_io.to_s.gsub(playbook, "PB")}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "--syntax-check" do
  it "prints only the playbook line and exits 0 for a valid playbook" do
    status, output = run_with(["--syntax-check"])
    status.exit_code.should eq(0)
    output.should eq("\nplaybook: PB\n")
  end

  it "exits 4 for an unparseable playbook" do
    status, _ = run_with(["--syntax-check"], "this: is: bad: [\n")
    status.exit_code.should eq(4)
  end

  it "does not run any task" do
    _, output = run_with(["--syntax-check"])
    output.should_not contain("PLAY RECAP")
    output.should_not contain("KRIKRI")
  end
end

describe "--list-tasks" do
  # Byte-for-byte real ansible-playbook output. Note the TAB before
  # TAGS, the alphabetical tag sort ([inner, outer] from a task tagged
  # `inner` inside a block tagged `outer`), and that "always inner" is
  # absent - real Ansible does not list a block's always: tasks.
  it "matches real ansible-playbook's listing exactly" do
    status, output = run_with(["--list-tasks"])
    status.exit_code.should eq(0)
    output.should eq(<<-OUT + "\n")

      playbook: PB

        play #1 (localhost): First play\tTAGS: []
          tasks:
            plain task\tTAGS: []
            tagged task\tTAGS: [alpha, beta]
            inner task\tTAGS: [inner, outer]

        play #2 (localhost): Second play\tTAGS: []
          tasks:
            second play task\tTAGS: []
      OUT
  end

  it "honors --tags, still printing an emptied play's header" do
    _, output = run_with(["--list-tasks", "--tags", "alpha"])
    output.should contain("tagged task\tTAGS: [alpha, beta]")
    output.should_not contain("plain task")
    # play #2 matches nothing but is still listed, with a bare tasks:
    output.should contain("play #2 (localhost): Second play")
    output.should_not contain("second play task")
  end

  it "prefixes a role's tasks with the role name" do
    dir = File.tempname("list-tasks-role")
    Dir.mkdir_p(File.join(dir, "roles", "r", "tasks"))
    File.write(File.join(dir, "roles", "r", "tasks", "main.yml"), <<-YAML)
      - name: role task
        ansible.builtin.debug: {msg: "R"}
        tags: [rt]
      YAML
    playbook = File.join(dir, "rp.yml")
    File.write(playbook, <<-YAML)
      - name: RolePlay
        hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - r
      YAML

    begin
      stdout_io = IO::Memory.new
      status = Process.run(BINARY, ["-i", INVENTORY, "--list-tasks", "rp.yml"],
        output: stdout_io, error: stdout_io, chdir: dir)
      status.exit_code.should eq(0)
      stdout_io.to_s.should contain("r : role task\tTAGS: [rt]")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "does not run any task" do
    _, output = run_with(["--list-tasks"])
    output.should_not contain("PLAY RECAP")
    output.should_not contain("KRIKRI")
  end
end
