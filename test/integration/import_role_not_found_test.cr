require "file_utils"
require "../minitest_helper"

# A STATIC import_role: naming a missing role - Ansible's exact stderr
# shapes live-verified against ansible-core 2.21.6 (issue #94). Two
# cases: the parse-time refusal at the top level (rc=1, Origin block),
# and the run-time fatal through an include_tasks:-loaded file inside a
# role (rc=2, a single "[ERROR]" + Origin block on stdout, then the
# per-host fatal line carrying the message under "msg").
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(dir : String, playbook_name : String = "site.yml") : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, File.join(dir, playbook_name)], output: output, error: output)
  {status, output.to_s}
end

describe "static import_role: naming a missing role" do
  it "points the Origin at the k=v string value itself, with the source excerpt" do
    # k=v string form (`import_role: name=...`) has no `name` KEY in the
    # source map, so the Origin used to be dropped entirely and only the
    # first [ERROR] line printed. Real points at the import_role VALUE's
    # first char (site.yml:5:20 - column 20 is where `name=...` starts).
    dir = PluginSpecHelper.tmp_path("import-role-missing-kv", Random::Secure.hex(4))
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - import_role: name=nonexistent.role
      YAML

    status, output = run_playbook(dir)

    output.must_include("[ERROR]: The role 'nonexistent.role' was not found in: #{dir}/roles:")
    output.must_include("Origin: #{dir}/site.yml:5:20")
    output.must_include("3   connection: local")
    output.must_include("4   tasks:")
    output.must_include("5     - import_role: name=nonexistent.role")
    output.must_include("  ^ column 20")
    exit_code = status.exit_code
    exit_code.must_equal(1)

    FileUtils.rm_rf(dir)
  end

  it "keeps the mapping form's Origin at the name value" do
    # The mapping form (import_role:\n  name: x) was already correct and
    # must not regress: real points at the name VALUE, not the task key.
    dir = PluginSpecHelper.tmp_path("import-role-missing-map", Random::Secure.hex(4))
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - import_role:
              name: nonexistent.role
      YAML

    status, output = run_playbook(dir)

    output.must_include("[ERROR]: The role 'nonexistent.role' was not found in: #{dir}/roles:")
    output.must_include("Origin: #{dir}/site.yml:5:15")
    exit_code = status.exit_code
    exit_code.must_equal(1)

    FileUtils.rm_rf(dir)
  end

  it "reports the playbook-dir search list for an import_role: in a role's own tasks/main.yml" do
    # Real 2.19 reports <playbook>/roles:...:<playbook>, not the
    # role's tasks/ dir, however deep the import sits.
    dir = PluginSpecHelper.tmp_path("import-role-missing-in-role", Random::Secure.hex(4))
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(File.join(dir, "roles", "r1", "tasks"))
    File.write(File.join(dir, "roles", "r1", "tasks", "main.yml"), <<-YAML)
      - import_role:
          name: nonexistent.role
      YAML
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        roles:
          - r1
      YAML

    status, output = run_playbook(dir)

    output.must_include("[ERROR]: The role 'nonexistent.role' was not found in: #{dir}/roles:")
    output.must_include(":#{dir}\n")
    output.wont_include("tasks/roles")
    exit_code = status.exit_code
    exit_code.must_equal(1)

    FileUtils.rm_rf(dir)
  end

  it "reports Ansible's single error block and changed+msg fatal through an include_tasks:-loaded role file" do
    # roles/r3/tasks/sub/x.yml does `import_role: name=nonexistent.role`:
    # the include task itself is Ansible's fatal include failure (issue
    # #1570, live-verified vs 2.21.6: ONE "[ERROR]" message with the
    # Origin at x.yml:1:16 on stdout, then `fatal: [host]` carrying the
    # message under "msg"), the play halts for the host (rc=2). The
    # search-path display follows the PLAYBOOK dir, not the including
    # file's own tasks/sub/ directory, and there is no "Failed to load
    # included tasks" degradation line.
    dir = PluginSpecHelper.tmp_path("import-role-missing-included", Random::Secure.hex(4))
    FileUtils.mkdir_p(File.join(dir, "roles", "r3", "tasks", "sub"))
    File.write(File.join(dir, "roles", "r3", "tasks", "main.yml"), <<-YAML)
      - include_tasks: sub/x.yml
      YAML
    File.write(File.join(dir, "roles", "r3", "tasks", "sub", "x.yml"), <<-YAML)
      - import_role: name=nonexistent.role
      YAML
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles: [r3]
      YAML

    status, output = run_playbook(dir)

    output.must_include("[ERROR]: The role 'nonexistent.role' was not found in: #{dir}/roles:")
    output.must_include("Origin: #{dir}/roles/r3/tasks/sub/x.yml:1:16")
    output.wont_include("<<< caused by >>>")
    output.wont_include(%("reason":))
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "The role 'nonexistent.role' was not found in: #{dir}/roles:))
    output.wont_include("tasks/sub/roles")
    output.wont_include("Failed to load included tasks")
    output.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1\s+skipped=0\s+rescued=0\s+ignored=0/)
    exit_code = status.exit_code
    exit_code.must_equal(2)

    FileUtils.rm_rf(dir)
  end

  it "prints no fatal line for a looped include_tasks: whose file has a missing import_role:" do
    # Real 2.21.6 (live-verified): when the include_tasks: is LOOPED, the
    # missing-role failure prints only the single "[ERROR]" block per
    # item; the per-host fatal: line is gone, but the recap still counts
    # failed=1 and rc stays 2.
    dir = PluginSpecHelper.tmp_path("import-role-missing-looped", Random::Secure.hex(4))
    FileUtils.mkdir_p(File.join(dir, "roles", "r4", "tasks"))
    File.write(File.join(dir, "roles", "r4", "tasks", "main.yml"), <<-YAML)
      - include_tasks: inst.yml
        loop: [a]
        loop_control:
          loop_var: instance
      YAML
    File.write(File.join(dir, "roles", "r4", "tasks", "inst.yml"), <<-YAML)
      - import_role:
          name: nonexistent.role
      YAML
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        roles: [r4]
      YAML

    status, output = run_playbook(dir)

    output.must_include("[ERROR]: The role 'nonexistent.role' was not found in: #{dir}/roles:")
    output.wont_include("<<< caused by >>>")
    output.wont_include("fatal: [localhost]")
    output.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1\s+skipped=0\s+rescued=0\s+ignored=0/)
    exit_code = status.exit_code
    exit_code.must_equal(2)

    FileUtils.rm_rf(dir)
  end

  it "writes the block to stdout exactly once, ahead of the fatal line, never to stderr" do
    # Issue #1570 (philnewm.foreman): the block belongs to the include
    # task's own result, so the default callback prints it on stdout
    # (display_failed_stderr defaults to false). krikri printed the
    # 2.19-era wrapped three-message block on stderr, which put it after
    # the recap as soon as the two streams were captured separately.
    dir = PluginSpecHelper.tmp_path("import-role-missing-stdout", Random::Secure.hex(4))
    FileUtils.mkdir_p(File.join(dir, "roles", "r5", "tasks"))
    File.write(File.join(dir, "roles", "r5", "tasks", "main.yml"), <<-YAML)
      - include_tasks: repo.yml
      YAML
    File.write(File.join(dir, "roles", "r5", "tasks", "repo.yml"), <<-YAML)
      - name: Include puppet repositories
        ansible.builtin.import_role:
          name: theforeman.operations.puppet_repositories
      YAML
    File.write(File.join(dir, "site.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles: [r5]
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "site.yml"], output: stdout, error: stderr, chdir: dir)
    out = stdout.to_s

    stderr.to_s.wont_include("[ERROR]")
    origin_at = out.index!("Origin: #{dir}/roles/r5/tasks/repo.yml:3:11")
    fatal_at = out.index!(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "The role 'theforeman.operations.puppet_repositories' was not found in: ))
    recap_at = out.index!("PLAY RECAP")
    assert origin_at < fatal_at, "the [ERROR] block must precede the fatal line"
    assert fatal_at < recap_at, "the fatal line must precede the recap"
    out.each_line.count { |line| line.starts_with?("[ERROR]:") }.must_equal(1)
    status.exit_code.must_equal(2)

    FileUtils.rm_rf(dir)
  end
end
