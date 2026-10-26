require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug shows in the
# executor's output/recap handling for a dynamic include_role: whose loop
# resolves to zero items, so it needs an end-to-end run rather than a unit
# test.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

describe "include_role: with a loop that resolves to zero items" do
  it "prints one bare skipping line and counts the task as skipped=1" do
    # Real ansible-core 2.19.11 (live-verified, issue #604): a looped
    # include_role: whose loop is empty reports a single bare
    # `skipping: [host]` line - no `(item=...)`, no suffix - and counts
    # skipped=1 in the recap. This engine ran zero loop iterations instead,
    # printing nothing at all and not counting the task at all (the shape
    # pluggero.tool_installer hit with an empty dependency-role list).
    src_dir = File.tempname("include-role-empty-loop-skip")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          dep_roles: []
        tasks:
          - name: Execute dependency roles
            include_role:
              name: "{{ role_name }}"
            loop: "{{ dep_roles }}"
            loop_control:
              loop_var: role_name
            when: dep_roles is defined and dep_roles | length > 0
      YAML

    output = `cd #{src_dir} && #{BINARY} -i #{INVENTORY} pb.yml 2>&1`
    exit_code = $?.exit_code

    output.must_match(/(?m)^skipping: \[localhost\]$/)
    output.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=0\s+skipped=1\s+rescued=0\s+ignored=0/)
    exit_code.must_equal(0)

    FileUtils.rm_rf(src_dir)
  end
end
