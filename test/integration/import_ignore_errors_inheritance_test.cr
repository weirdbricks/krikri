require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - both fixes are
# runtime inheritance paths (parse-time import_tasks: keyword merge,
# TaskExecutor#run_include_role_once's static import_role: load), which
# need a full play execution to exercise.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

# Real inherits an import statement's ignore_errors: onto every task the
# import statically inlines (FieldAttribute inherit rule, live-verified
# vs ansible-core 2.19.11) - so a when:-failing inlined task under an
# `ignore_errors: true` import prints "...ignoring" and books
# ok+=1/ignored+=1 with exit 0, instead of a fatal. Found via
# krikri-playbook-generator's multi-import_role-happy playbook (issue
# #1121): the inlined task's inherited when: referenced a register:
# from the preceding import_role: (register: is NOT inherited - real
# leaves it undefined), the conditional evaluation failed, and this
# engine fatallied with failed=1 / exit 2 where real continued.
describe "a static import statement's ignore_errors: is inherited by its inlined tasks" do
  it "ignores an inlined import_tasks: child's when:-evaluation failure like real (...ignoring, ignored=1, exit 0)" do
    src_dir = File.tempname("import-tasks-ignore-errors")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "children.yml"), <<-YAML)
      - name: child task
        debug:
          msg: child
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: import children
            import_tasks: children.yml
            ignore_errors: true
            when: never_registered_var is succeeded
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("'never_registered_var' is undefined")
    output.to_s.must_include("fatal: [localhost]")
    output.to_s.must_include("...ignoring")
    output.to_s.must_match(/ignored=1\b/)
    output.to_s.wont_match(/failed=[1-9]/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "ignores a loaded import_role: child's module failure like real (...ignoring, ok=1 ignored=1, exit 0)" do
    src_dir = File.tempname("import-role-ignore-errors-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "failrole", "tasks"))
    File.write(File.join(src_dir, "roles", "failrole", "tasks", "main.yml"), <<-YAML)
      - name: role task that fails
        fail:
          msg: role-boom
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: import failing role
            import_role:
              name: failrole
            ignore_errors: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("fatal: [localhost]")
    output.to_s.must_include("...ignoring")
    output.to_s.must_match(/ok=1\b/)
    output.to_s.must_match(/ignored=1\b/)
    output.to_s.wont_match(/failed=[1-9]/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
