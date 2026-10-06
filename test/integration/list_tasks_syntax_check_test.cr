require "file_utils"
require "../minitest_helper"

# --syntax-check and --list-tasks. The expected output below is the
# VERBATIM output of a ansible-core 2.19.4 run of the same playbook
# (tabs included), not a reconstruction - these two modes are routinely
# machine-read in CI, so the exact shape matters.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

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
    status.exit_code.must_equal(0)
    output.must_equal("\nplaybook: PB\n")
  end

  it "exits 4 for an unparseable playbook" do
    status, _ = run_with(["--syntax-check"], "this: is: bad: [\n")
    status.exit_code.must_equal(4)
  end

  it "does not run any task" do
    _, output = run_with(["--syntax-check"])
    output.wont_include("PLAY RECAP")
    output.wont_include("KRIKRI")
  end
end

describe "--list-tasks" do
  # Byte-for-byte ansible-playbook output. Note the TAB before
  # TAGS, the alphabetical tag sort ([inner, outer] from a task tagged
  # `inner` inside a block tagged `outer`), and that "always inner" is
  # absent - Ansible does not list a block's always: tasks.
  it "matches ansible-playbook's listing exactly" do
    status, output = run_with(["--list-tasks"])
    status.exit_code.must_equal(0)
    output.must_equal(<<-OUT + "\n")

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
    output.must_include("tagged task\tTAGS: [alpha, beta]")
    output.wont_include("plain task")
    # play #2 matches nothing but is still listed, with a bare tasks:
    output.must_include("play #2 (localhost): Second play")
    output.wont_include("second play task")
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
      status.exit_code.must_equal(0)
      stdout_io.to_s.must_include("r : role task\tTAGS: [rt]")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "does not run any task" do
    _, output = run_with(["--list-tasks"])
    output.wont_include("PLAY RECAP")
    output.wont_include("KRIKRI")
  end

  # Real (2.19.11) lists an unnamed task by its action AS WRITTEN - the
  # FQCN key verbatim, no role prefix and no name synthesis - and an
  # unnamed include_tasks:/meta:/include_vars: the same way.
  it "lists unnamed tasks by their action as written, FQCN included" do
    yaml = <<-YAML
      - hosts: localhost
        gather_facts: false
        tasks:
          - ansible.builtin.include_tasks: tasks/x.yml
          - ansible.builtin.debug: {msg: x}
            tags: [fq]
          - include_tasks: tasks/x.yml
          - meta: flush_handlers
          - ansible.builtin.include_vars: {file: x.yml}
      YAML
    dir = File.tempname("list-tasks-fqcn")
    Dir.mkdir_p(File.join(dir, "tasks"))
    File.write(File.join(dir, "tasks", "x.yml"), "- name: inner\n  debug: {msg: i}\n")
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, yaml)

    begin
      stdout_io = IO::Memory.new
      status = Process.run(BINARY, ["-i", INVENTORY, "--list-tasks", "pb.yml"],
        output: stdout_io, error: stdout_io, chdir: dir)
      status.exit_code.must_equal(0)
      stdout_io.to_s.must_equal(<<-OUT + "\n")

        playbook: pb.yml

          play #1 (localhost): localhost\tTAGS: []
            tasks:
              ansible.builtin.include_tasks\tTAGS: []
              ansible.builtin.debug\tTAGS: [fq]
              include_tasks\tTAGS: []
              meta\tTAGS: []
              ansible.builtin.include_vars\tTAGS: []
        OUT
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end

# A STATIC import_role: is resolved by ansible-core at parse time and
# spliced into the play's compiled task list, so --list-tasks/--list-tags
# list the role's own tasks ("role : task" names, the import's tags
# unioned onto them) where a DYNAMIC include_role: statement is listed
# unexpanded. Every expected output below is the verbatim ansible-core
# 2.19.11 output of the same fixture.
describe "--list-tasks with import_role" do
  # Roles: testrole (named + unnamed tasks, import_tasks, a nested
  # import_role, a dynamic include_role), nestedrole (imported BY
  # testrole), othertask (also listed as a roles: entry for comparison).
  private def build_import_fixture
    dir = File.tempname("list-tasks-import")
    Dir.mkdir_p(File.join(dir, "roles", "testrole", "tasks"))
    Dir.mkdir_p(File.join(dir, "roles", "nestedrole", "tasks"))
    Dir.mkdir_p(File.join(dir, "roles", "othertask", "tasks"))
    File.write(File.join(dir, "roles", "testrole", "tasks", "main.yml"), <<-YAML)
      - name: main task one
        debug:
          msg: one
        tags: [t1]
      - debug:
          msg: unnamed
      - name: import tasks file
        import_tasks: subtasks.yml
        tags: [t2]
      - name: nested import role
        import_role:
          name: nestedrole
        tags: [t3]
      - name: dynamic include role
        include_role:
          name: othertask
        tags: [t4]
      YAML
    File.write(File.join(dir, "roles", "testrole", "tasks", "subtasks.yml"), <<-YAML)
      - name: sub task a
        debug:
          msg: a
        tags: [tsub]
      YAML
    File.write(File.join(dir, "roles", "nestedrole", "tasks", "main.yml"), <<-YAML)
      - name: nested role task
        debug:
          msg: nested
        tags: [tnested]
      YAML
    File.write(File.join(dir, "roles", "othertask", "tasks", "main.yml"), <<-YAML)
      - name: other role task
        debug:
          msg: other
        tags: [tother]
      YAML
    dir
  end

  private def run_in(dir : String, args : Array(String))
    stdout_io = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY] + args + ["pb.yml"],
      output: stdout_io, error: stdout_io, chdir: dir)
    {status, stdout_io.to_s}
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "expands a static import_role like ansible-playbook, byte for byte" do
    dir = build_import_fixture
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          dynrole: othertask
        roles:
          - role: othertask
            tags: [roletag]
        tasks:
          - name: static import role
            import_role:
              name: testrole
            tags: [imp]
          - name: static import with tasks_from
            import_role:
              name: testrole
              tasks_from: subtasks.yml
            tags: [imp2]
          - name: templated static import
            import_role:
              name: "{{ dynrole }}"
            tags: [imp3]
          - name: plain task
            debug:
              msg: plain
            tags: [plain]
      YAML

    status, output = run_in(dir, ["--list-tasks"])
    status.exit_code.must_equal(0)
    # Verbatim ansible-core 2.19.11 output: the import statements never
    # appear, their tags merge onto the loaded tasks, the unnamed role
    # task lists as the bare action, the nested import_role expands, and
    # the dynamic include_role statement IS listed (unexpanded).
    output.must_equal(<<-OUT + "\n")

      playbook: pb.yml

        play #1 (localhost): localhost\tTAGS: []
          tasks:
            othertask : other role task\tTAGS: [roletag, tother]
            testrole : main task one\tTAGS: [imp, t1]
            debug\tTAGS: [imp]
            testrole : sub task a\tTAGS: [imp, t2, tsub]
            nestedrole : nested role task\tTAGS: [imp, t3, tnested]
            dynamic include role\tTAGS: [imp, t4]
            testrole : sub task a\tTAGS: [imp2, tsub]
            othertask : other role task\tTAGS: [imp3, tother]
            plain task\tTAGS: [plain]
      OUT
  end

  it "unions the imported tasks' tags in --list-tags like ansible-playbook" do
    dir = build_import_fixture
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - role: othertask
            tags: [roletag]
        tasks:
          - name: static import role
            import_role:
              name: testrole
            tags: [imp]
          - name: plain task
            debug:
              msg: plain
            tags: [plain]
      YAML

    status, output = run_in(dir, ["--list-tags"])
    status.exit_code.must_equal(0)
    output.must_equal(<<-OUT + "\n")

      playbook: pb.yml

        play #1 (localhost): localhost\tTAGS: []
            TASK TAGS: [imp, plain, roletag, t1, t2, t3, t4, tnested, tother, tsub]
      OUT
  end

  it "expands the same role imported twice and lists block children under the role's name" do
    dir = File.tempname("list-tasks-import-block")
    Dir.mkdir_p(File.join(dir, "roles", "blockrole", "tasks"))
    Dir.mkdir_p(File.join(dir, "roles", "nestedrole", "tasks"))
    File.write(File.join(dir, "roles", "blockrole", "tasks", "main.yml"), <<-YAML)
      - name: role top task
        debug: {msg: top}
        tags: [rt]
      - name: role block
        block:
          - name: in role block named
            debug: {msg: x}
            tags: [rb]
          - debug: {msg: y}
      YAML
    File.write(File.join(dir, "roles", "nestedrole", "tasks", "main.yml"), <<-YAML)
      - name: nested role task
        debug: {msg: nested}
        tags: [tnested]
      YAML
    FileUtils.mkdir_p(File.join(dir, "roles", "chain", "tasks"))
    File.write(File.join(dir, "roles", "chain", "tasks", "main.yml"), <<-YAML)
      - name: chain imports nested
        import_role:
          name: nestedrole
        tags: [ct]
      YAML
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - blockrole
        tasks:
          - import_role:
              name: blockrole
            tags: [imp5]
          - import_role:
              name: chain
            tags: [top]
          - import_role:
              name: chain
            tags: [top2]
      YAML

    status, output = run_in(dir, ["--list-tasks"])
    status.exit_code.must_equal(0)
    # Verbatim ansible-core 2.19.11: blocks are flattened in the listing,
    # a NAMED block child gets the "role : " prefix (both via a roles:
    # entry and via import_role), and each import statement expands the
    # role afresh - a second import of the same role lists its tasks
    # again under the second import's tags.
    output.must_equal(<<-OUT + "\n")

      playbook: pb.yml

        play #1 (localhost): localhost\tTAGS: []
          tasks:
            blockrole : role top task\tTAGS: [rt]
            blockrole : in role block named\tTAGS: [rb]
            debug\tTAGS: []
            blockrole : role top task\tTAGS: [imp5, rt]
            blockrole : in role block named\tTAGS: [imp5, rb]
            debug\tTAGS: [imp5]
            nestedrole : nested role task\tTAGS: [ct, tnested, top]
            nestedrole : nested role task\tTAGS: [ct, tnested, top2]
      OUT
  end

  it "refuses the playbook when a static import_role's tasks_from file is missing" do
    dir = build_import_fixture
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - import_role:
              name: testrole
              tasks_from: nonexistent
      YAML

    status, output = run_in(dir, ["--list-tasks"])
    # ansible-core 2.19.11 (role/__init__.py, AnsibleParserError): empty
    # stdout, a plain [ERROR]: line on stderr, no Origin block, rc=4.
    status.exit_code.must_equal(4)
    output.wont_include("play #1")
    output.must_include("[ERROR]: Could not find specified file in role: tasks/nonexistent")
  end
end
