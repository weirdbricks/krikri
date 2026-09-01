require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in
# TaskExecutor#run_include_role_once's controller-side static-import
# handling, which needs a real role load + when: propagation to
# exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "import_role: with when: expands and propagates onto every one of the role's own tasks" do
  it "shows each inner task individually skipped when the import's own when: is false, instead of one silent no-op" do
    # Real bug found benchmarking brunobenchimol.certbot_dns (round855):
    # real Ansible resolves import_role: statically and combines its
    # when: onto EVERY task the role expands to - the import line
    # itself produces no result of its own, only its expanded children
    # do. A false when: on the import must still show each inner task
    # as "TASK [...]" / "skipping:" under its own real name. This
    # engine instead returned early with nothing printed at all,
    # undercounting `skipped` by the whole role's task count (real
    # Ansible's recap: ok=8 skipped=40; this engine's: ok=9 skipped=21).
    src_dir = File.tempname("import-role-when-expansion-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "inner", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "tasks"))
    File.write(File.join(src_dir, "roles", "inner", "tasks", "main.yml"), <<-YAML)
      - name: inner task one
        debug:
          msg: one
      - name: inner task two
        debug:
          msg: two
      YAML
    File.write(File.join(src_dir, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - name: import inner conditionally
        import_role:
          name: inner
        when: should_run
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          should_run: false
        roles:
          - outer
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("TASK [inner task one]")
    output.to_s.should contain("TASK [inner task two]")
    output.to_s.should_not contain("TASK [import inner conditionally]")
    output.to_s.should match(/skipped=2\b/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still runs every inner task normally when the import's own when: is true" do
    src_dir = File.tempname("import-role-when-expansion-true-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "inner", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "tasks"))
    File.write(File.join(src_dir, "roles", "inner", "tasks", "main.yml"), <<-YAML)
      - name: inner task one
        debug:
          msg: one
      YAML
    File.write(File.join(src_dir, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - name: import inner conditionally
        import_role:
          name: inner
        when: should_run
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          should_run: true
        roles:
          - outer
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should match(/ok=1\b/)
    output.to_s.should_not match(/skipped=[1-9]/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "does not evaluate a child's own when: (which would raise on an unregistered var) once the parent gate is false - short-circuit AND" do
    # Guards the "parent when: PREPENDED not appended" ordering
    # (playbook_parser.cr's try_parse_import_tasks already documents
    # this for import_tasks: - the identical fix for import_role: here
    # must short-circuit the same way, or a child referencing a
    # register: from a task the parent gate skipped would abort the
    # whole play instead of being cleanly skipped).
    src_dir = File.tempname("import-role-when-short-circuit-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "inner", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "tasks"))
    File.write(File.join(src_dir, "roles", "inner", "tasks", "main.yml"), <<-YAML)
      - name: probe
        command: echo hi
        register: probe_result
        when: some_other_gate
      - name: uses probe result
        debug:
          msg: "{{ probe_result.stdout }}"
        when: probe_result.stdout is defined
      YAML
    File.write(File.join(src_dir, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - name: import inner conditionally
        import_role:
          name: inner
        when: should_run
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          should_run: false
        roles:
          - outer
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should_not contain("is undefined")
    output.to_s.should match(/skipped=2\b/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
