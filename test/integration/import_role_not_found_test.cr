require "file_utils"
require "../minitest_helper"

# A STATIC import_role: naming a missing role - Ansible's exact stderr
# shapes live-verified against ansible-core 2.19.11 (issue #94). Two
# cases: the parse-time refusal at the top level (rc=1, Origin block),
# and the run-time fatal through an include_tasks:-loaded file inside a
# role (rc=2, wrapped <<< caused by >>> block + per-host fatal line).
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

    output.must_include("[ERROR]: the role 'nonexistent.role' was not found in #{dir}/roles:")
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

    output.must_include("[ERROR]: the role 'nonexistent.role' was not found in #{dir}/roles:")
    output.must_include("Origin: #{dir}/site.yml:5:15")
    exit_code = status.exit_code
    exit_code.must_equal(1)

    FileUtils.rm_rf(dir)
  end

  it "reports Ansible's wrapped fatal through an include_tasks:-loaded role file" do
    # roles/r3/tasks/sub/x.yml does `import_role: name=nonexistent.role`:
    # the include task itself is Ansible's fatal include failure (the
    # three-message <<< caused by >>> block on stderr with the Origin at
    # x.yml:1:16, then `fatal: [host]` with the as-written include and
    # the not-found reason), the play halts for the host (rc=2). The
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

    output.must_include("[ERROR]: the role 'nonexistent.role' was not found in #{dir}/roles:")
    output.must_include("\n\nthe role 'nonexistent.role' was not found in #{dir}/roles:")
    output.must_include("<<< caused by >>>")
    output.must_include("Origin: #{dir}/roles/r3/tasks/sub/x.yml:1:16")
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "include": "sub/x.yml", "reason": "the role 'nonexistent.role' was not found in #{dir}/roles:))
    output.wont_include("tasks/sub/roles")
    output.wont_include("Failed to load included tasks")
    output.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1\s+skipped=0\s+rescued=0\s+ignored=0/)
    exit_code = status.exit_code
    exit_code.must_equal(2)

    FileUtils.rm_rf(dir)
  end
end
