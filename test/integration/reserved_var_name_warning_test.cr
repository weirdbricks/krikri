require "../minitest_helper"
require "file_utils"

# A play-level `vars:` entry using one of ansible-core's reserved variable
# names warns at load time; a TASK-level one warns lazily, when the
# strategy actually reaches the task (ansible's VariableManager.get_vars):
# "[WARNING]: Found variable using reserved name 'X'." + an Origin block
# naming the var key's own position, one blank line after each block.
# Byte-for-byte vs ansible-playbook 2.19.11 (pr.yml-shape probes via
# scripts/output_parity.sh).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "reserved variable name warning" do
  it "warns for play vars and task vars with the key's own Origin" do
    playbook = File.tempname("reserved-var", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          range: "x"
          with_items: "not reserved"
        tasks:
          - debug: msg="hi"
            vars:
              lookup: "y"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'range'.")
    text.must_include("[WARNING]: Found variable using reserved name 'lookup'.")
    # `with_items` (a prefix-form reserved entry) never warns
    refute(text.includes?("[WARNING]: Found variable using reserved name 'with_items'."))
    text.must_include("Origin: #{playbook}:4:5")
    text.must_include("Origin: #{playbook}:9:9")
    # exactly one Origin block per warning, blank line after each
    text.scan("Found variable using reserved name").size.must_equal(2)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # ansible warns only when a task executes, so a load refused before the
  # first task (removed `include:`) shows no reserved-name warning
  # (live-verified vs ansible-core 2.19.11, issue #634).
  it "does not warn for a reserved task var when the load is refused by a removed include" do
    playbook = File.tempname("reserved-var-refused", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - debug: msg="hi"
            vars:
              roles: "x"
          - include: users.yml
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("has been removed")
    refute(text.includes?("reserved name 'roles'"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Same refusal shape but via a runtime include_tasks load: Ansible
  # evaluates a task's vars only at execution, so the included file's
  # reserved-name warnings never fire when its own removed `include:`
  # aborts the load first (live-verified vs 2.19.11, issue #634).
  it "does not warn for a reserved task var in an include_tasks file refused by a removed include" do
    dir = File.tempname("reserved-var-include")
    Dir.mkdir_p(dir)
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - include_tasks: projects.yml
      YAML
    tasks_file = File.join(dir, "projects.yml")
    File.write(tasks_file, <<-YAML)
      - debug: msg="hi"
        vars:
          roles: "x"
      - include: users.yml
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("has been removed")
    refute(text.includes?("reserved name 'roles'"))
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # ansible-core 2.19 warns for a task's `register:` name too (issue
  # #469): Origin points at the register VALUE token - the line of
  # `register:`, the column of the first character after `register:` and
  # its spaces.
  it "warns for a reserved register name with the value token's Origin" do
    playbook = File.tempname("reserved-register", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: get date
            command: 'date +%s'
            register: now
          - debug: msg="hi"
            register: not_reserved_at_all
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'now'.")
    text.must_include("Origin: #{playbook}:6:17")
    # a non-reserved register name never warns
    refute(text.includes?("not_reserved_at_all"))
    text.scan("Found variable using reserved name").size.must_equal(1)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "points include_role's `name` warning at the vars entry, not the module's own name key" do
    dir = File.tempname("reserved-var-role")
    Dir.mkdir_p(File.join(dir, "roles", "myrole", "tasks"))
    File.write(File.join(dir, "roles", "myrole", "tasks", "main.yml"), "- debug: msg=hi\n")
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - include_role:
              name: myrole
            vars:
              name: foo
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    output.to_s.must_include("Origin: #{playbook}:7:9")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # issue #1594 (ivansible.cert_cloudflare): ansible's load_list_of_tasks
  # get_vars's every include_tasks:/import_tasks: statement while loading
  # it, so these warn BEFORE the PLAY banner and even when an earlier
  # failure means the statement is never reached. Only a plain task's
  # vars wait for execution (the #473 tests below).
  it "warns at load for an include_tasks reserved var the play never reaches" do
    dir = File.tempname("reserved-var-unreached-include")
    Dir.mkdir_p(dir)
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - fail: msg=boom
          - name: setup account
            include_tasks: inc.yml
            vars:
              name: x
      YAML
    File.write(File.join(dir, "inc.yml"), "- debug: msg=hi\n")
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: dir)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'name'.")
    text.must_include("Origin: #{playbook}:8:9")
    text.must_include("fatal: [localhost]")
    warn_at = text.index!("[WARNING]: Found variable using reserved name")
    play_at = text.index!("PLAY [")
    (warn_at < play_at).must_equal(true)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "warns at load for an import_tasks reserved var the play never reaches" do
    dir = File.tempname("reserved-var-unreached-import")
    Dir.mkdir_p(dir)
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - fail: msg=boom
          - name: setup account
            import_tasks: inc.yml
            vars:
              lookup: x
      YAML
    File.write(File.join(dir, "inc.yml"), "- debug: msg=hi\n")
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: dir)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'lookup'.")
    text.must_include("Origin: #{playbook}:8:9")
    warn_at = text.index!("[WARNING]: Found variable using reserved name")
    play_at = text.index!("PLAY [")
    (warn_at < play_at).must_equal(true)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # import_role: is statically spliced and get_vars'd at load exactly like
  # import_tasks:, while include_role: (the dynamic form, covered above)
  # only sees get_vars when the statement runs - unreached stays silent.
  it "warns at load for an unreached import_role reserved var but not for an unreached include_role" do
    dir = File.tempname("reserved-var-role-import")
    Dir.mkdir_p(File.join(dir, "roles", "myrole", "tasks"))
    File.write(File.join(dir, "roles", "myrole", "tasks", "main.yml"), "- debug: msg=hi\n")
    import_playbook = File.join(dir, "pb_import.yml")
    File.write(import_playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - fail: msg=boom
          - name: call role
            import_role:
              name: myrole
            vars:
              name: x
      YAML
    include_playbook = File.join(dir, "pb_include.yml")
    File.write(include_playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - fail: msg=boom
          - name: call role
            include_role:
              name: myrole
            vars:
              name: x
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, import_playbook], output: output, error: output, chdir: dir)
    text = output.to_s
    text.must_include("[WARNING]: Found variable using reserved name 'name'.")
    text.must_include("Origin: #{import_playbook}:9:9")

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, include_playbook], output: output, error: output, chdir: dir)
    refute(output.to_s.includes?("Found variable using reserved name"))
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # issue #473 (danielmschmidt.ansible_docker_systemd_traefik_service):
  # ansible warns a task's reserved-name vars from get_vars, i.e. only
  # when the strategy reaches the task - an earlier failure that ends the
  # play keeps the later task's warning from ever printing, where a
  # load-time print fired before the PLAY banner was even out.
  it "does not warn for a reserved task var on a task the play never reaches" do
    playbook = File.tempname("reserved-var-unreached", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - fail: msg=boom
          - debug: msg="hi"
            vars:
              name: x
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("fatal: [localhost]")
    refute(text.includes?("Found variable using reserved name"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "warns for a reserved task var only once the task actually runs" do
    playbook = File.tempname("reserved-var-reached", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - debug: msg="hi"
            vars:
              name: x
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'name'.")
    text.must_include("Origin: #{playbook}:6:9")
    # the warning is a run-time event now: the PLAY banner is out first
    play_at = text.index!("PLAY [")
    warn_at = text.index!("[WARNING]: Found variable using reserved name")
    (play_at < warn_at).must_equal(true)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
