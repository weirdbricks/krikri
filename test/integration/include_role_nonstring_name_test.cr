require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the abort is in the
# executor's dynamic include_role: dispatch (the whole run dies after the
# task banner), so it needs an end-to-end run rather than a unit test.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

describe "include_role: with a non-string name" do
  it "aborts the whole run after the task banner, ignoring ignore_errors (rc=4, no recap)" do
    # Real 2.19.11 (live-verified, issue #761): IncludeRole.load only
    # requires the name/role KEY - the type check happens later, in
    # RoleInclude.load's "Invalid role definition.", which for the
    # dynamic form runs at RUN time. The exception escapes the task
    # executor entirely: the task banner prints, then the [ERROR] block
    # with the name VALUE's own Origin goes to stderr, and the run dies
    # with rc=4 - no fatal: line, no recap, and ignore_errors: never
    # applies (the task never produces a result). The old engine
    # behavior - a parse-time "Skipping task ... missing required
    # 'name'" warning that silently emptied the play - was wrong.
    src_dir = File.tempname("include-role-nonstring-name")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include bad role
            ansible.builtin.include_role:
              name: 50
            ignore_errors: true
          - name: After
            debug:
              msg: should not run
      YAML

    output = `cd #{src_dir} && #{BINARY} -i #{INVENTORY} pb.yml 2>&1`
    exit_code = $?.exit_code

    output.must_include("TASK [include bad role]")
    output.must_include("[ERROR]: Invalid role definition.")
    output.must_include("Origin: #{playbook}:7:15")
    output.must_include("^ column 15")
    output.wont_include("Skipping task in play")
    output.wont_include("fatal:")
    output.wont_include("PLAY RECAP")
    output.wont_include("should not run")
    exit_code.must_equal(4)

    FileUtils.rm_rf(src_dir)
  end

  it "renders an untagged bool name as Origin: <unknown> plus the Python repr" do
    # Real 2.19.11 (live-verified): bools ride no _AnsibleTagged class,
    # so the same failure carries no source position - the block renders
    # "Origin: <unknown>" plus the value's repr ("True") instead.
    src_dir = File.tempname("include-role-nonstring-name-bool")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include bool name
            ansible.builtin.include_role:
              name: true
      YAML

    output = `cd #{src_dir} && #{BINARY} -i #{INVENTORY} pb.yml 2>&1`
    exit_code = $?.exit_code

    output.must_include("TASK [include bool name]")
    output.must_include("[ERROR]: Invalid role definition.")
    output.must_include("Origin: <unknown>")
    output.must_include("\nTrue\n")
    exit_code.must_equal(4)

    FileUtils.rm_rf(src_dir)
  end

  it "refuses a static import_role: with a non-string name at load time (no play banner)" do
    # Real 2.19.11 (live-verified): a STATIC import_role: resolves the
    # role during playbook load, so the same "Invalid role definition."
    # refusal fires before any play banner - rc=4.
    src_dir = File.tempname("import-role-nonstring-name")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: import bad role
            ansible.builtin.import_role:
              name: 50
          - name: After
            debug:
              msg: should not run
      YAML

    output = `cd #{src_dir} && #{BINARY} -i #{INVENTORY} pb.yml 2>&1`
    exit_code = $?.exit_code

    output.must_include("[ERROR]: Invalid role definition.")
    output.must_include("Origin: #{playbook}:7:15")
    output.wont_include("PLAY [")
    output.wont_include("PLAY RECAP")
    output.wont_include("should not run")
    exit_code.must_equal(4)

    FileUtils.rm_rf(src_dir)
  end
end
