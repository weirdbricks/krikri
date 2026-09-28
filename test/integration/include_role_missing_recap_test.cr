require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in the
# executor's recap-counting for a dynamic include_role: whose target role
# doesn't exist, so it needs an end-to-end run rather than a unit test.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

describe "include_role: naming a role that doesn't exist" do
  it "counts the task as failed only, not failed AND ok, and halts the play for that host" do
    # Real bug found benchmarking andrewrothstein.libvirt (round 185): its
    # own tasks/main.yml does `include_role: name: andrewrothstein.qemu`,
    # a meta dependency that had been removed from Galaxy. Real Ansible
    # treats the failed dynamic role resolution as an ordinary fatal task
    # result - `ok=0 failed=1`, and the next task in the role never runs.
    # This engine counted the include_role: task as `ok` UNCONDITIONALLY
    # before even attempting to load the named role (to match real
    # Ansible's stats for the successful case - see run_include_role_once's
    # own comment), so a role that fails to load got double-counted:
    # `ok=1 failed=1` for the same single task.
    src_dir = File.tempname("include-role-missing-recap")
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "tasks"))
    File.write(File.join(src_dir, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - name: Installing missing role
        include_role:
          name: nonexistent_role_xyz
      - name: After the missing include
        debug:
          msg: should not run
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - outer
      YAML

    output = `cd #{src_dir} && #{BINARY} -i #{INVENTORY} pb.yml 2>&1`
    exit_code = $?.exit_code

    output.must_include("failed: [localhost]")
    output.must_include("Failed to load role 'nonexistent_role_xyz'")
    output.wont_include("should not run")
    output.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1/)
    exit_code.must_equal(2)

    FileUtils.rm_rf(src_dir)
  end
end
