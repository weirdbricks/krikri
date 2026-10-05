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
    # a meta dependency that had been removed from Galaxy. Ansible
    # treats the failed dynamic role resolution as an ordinary fatal task
    # result - `ok=0 failed=1`, and the next task in the role never runs.
    # This engine counted the include_role: task as `ok` UNCONDITIONALLY
    # before even attempting to load the named role (to match
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

    # Ansible 2.19.11's fatal include shape (live-verified, both from a play
    # task and from inside a role's own tasks): the loader's AnsibleError
    # goes to STDERR as an "[ERROR]: the role 'x' was not found in <search
    # paths>" block whose Origin points at the role-name VALUE inside the
    # role's own tasks file, the task result line is the two-key fatal
    # dump, and the play halts for that host unconditionally (ignore_
    # errors: does not apply - failed=1 ignored=0).
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "reason": "the role 'nonexistent_role_xyz' was not found in #{src_dir}/roles:))
    output.must_include("[ERROR]: the role 'nonexistent_role_xyz' was not found in ")
    output.must_include("Origin: #{src_dir}/roles/outer/tasks/main.yml:3:11")
    output.wont_include("should not run")
    output.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1\s+skipped=0\s+rescued=0\s+ignored=0/)
    exit_code.must_equal(2)

    FileUtils.rm_rf(src_dir)
  end
end

describe "include_tasks: naming a file that doesn't exist" do
  it "fails with Ansible's fatal include shape, ignoring ignore_errors:" do
    # Ansible 2.19.11 (live-verified): the DataLoader error block goes to
    # STDERR with no Origin, STDOUT gets the two-key fatal dump with the
    # as-written file under "include:", the task counts as failed only -
    # ignore_errors: does NOT apply (failed=1 ignored=0) - and the play
    # halts for that host (rc=2).
    src_dir = File.tempname("include-tasks-missing")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include missing
            ansible.builtin.include_tasks: nosuch_tasks.yml
            ignore_errors: true
          - name: After
            ansible.builtin.debug:
              msg: should not run
      YAML

    output = `cd #{src_dir} && #{BINARY} -i #{INVENTORY} pb.yml 2>&1`
    exit_code = $?.exit_code

    output.must_include("[ERROR]: Could not find or access '#{src_dir}/nosuch_tasks.yml' on the Ansible Controller: Unable to retrieve file contents.")
    output.must_include("If you are using a module and expect the file to exist on the remote, see the remote_src option: [Errno 2] No such file or directory: '#{src_dir}/nosuch_tasks.yml'")
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "include": "nosuch_tasks.yml", "reason": "Could not find or access '#{src_dir}/nosuch_tasks.yml'))
    output.wont_include("should not run")
    output.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1\s+skipped=0\s+rescued=0\s+ignored=0/)
    exit_code.must_equal(2)

    FileUtils.rm_rf(src_dir)
  end

  it "keeps a non-string literal file path's own type in the fatal dump" do
    # Ansible 2.19.11 (live-verified): the "include" value is echoed as the
    # playbook wrote it, so a YAML int stays a JSON int (`"include": 21`)
    # even though the path it resolved - and the error text - is that
    # value's Python str(). A bool keeps its own type too, while the path
    # uses "True" capitalization.
    {21 => "21", true => "True"}.each do |literal, path_text|
      src_dir = File.tempname("include-tasks-missing-literal")
      Dir.mkdir_p(src_dir)

      playbook = File.join(src_dir, "pb.yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: include missing
              ansible.builtin.include_tasks: {file: #{literal}}
      YAML

      output = `cd #{src_dir} && #{BINARY} -i #{INVENTORY} pb.yml 2>&1`
      exit_code = $?.exit_code

      output.must_include("Could not find or access '#{src_dir}/#{path_text}' on the Ansible Controller")
      output.must_include(%("include": #{literal}, "reason":))
      output.wont_include(%("include": "#{path_text}"))
      exit_code.must_equal(2)

      FileUtils.rm_rf(src_dir)
    end
  end
end
