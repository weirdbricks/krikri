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

    # Ansible 2.21.6's fatal include shape (live-verified, both from a play
    # task and from inside a role's own tasks): the loader's AnsibleError
    # goes to STDERR as an "[ERROR]: The role 'x' was not found in: <search
    # paths>" block whose Origin points at the role-name VALUE inside the
    # role's own tasks file, the task result line is the two-key fatal
    # dump, and the play halts for that host unconditionally (ignore_
    # errors: does not apply - failed=1 ignored=0).
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "reason": "The role 'nonexistent_role_xyz' was not found in: #{src_dir}/roles:))
    output.must_include("[ERROR]: The role 'nonexistent_role_xyz' was not found in: ")
    output.must_include("Origin: #{src_dir}/roles/outer/tasks/main.yml:3:11")
    output.wont_include("should not run")
    output.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1\s+skipped=0\s+rescued=0\s+ignored=0/)
    exit_code.must_equal(2)

    FileUtils.rm_rf(src_dir)
  end
end

describe "include_tasks: naming a file that doesn't exist" do
  it "fails with ansible-core 2.21's fatal include shape, ignoring ignore_errors:" do
    # Ansible 2.21.6 (live-verified): the DataLoader's AnsibleFileNotFound
    # is a TASK failure, so the default callback renders its event on
    # STDOUT as one "[ERROR]:" line folding in the chained OSError and the
    # help text, and the result dump carries the brief message under "msg"
    # only (no "include", no "reason"). The task counts as failed only -
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

    resolved = "#{src_dir}/nosuch_tasks.yml"
    output.must_include("[ERROR]: Unable to retrieve file contents. Could not find or access '#{resolved}' on the Ansible Controller: " \
                        "[Errno 2] No such file or directory: '#{resolved}' " \
                        "If you are using a module and expect the file to exist on the remote, see the remote_src option.\n")
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Unable to retrieve file contents. ) +
                        %(Could not find or access '#{resolved}' on the Ansible Controller: [Errno 2] No such file or directory: '#{resolved}'"}))
    output.wont_include(%("include":))
    output.wont_include(%("reason":))
    output.wont_include("should not run")
    output.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1\s+skipped=0\s+rescued=0\s+ignored=0/)
    exit_code.must_equal(2)

    FileUtils.rm_rf(src_dir)
  end

  it "prints the missing-file error block on STDOUT, ahead of the fatal line" do
    # Issue #1093 (shifteoops.apache_role): the block belongs to the task
    # RESULT, so the callback writes it to stdout (display_failed_stderr
    # defaults to False). krikri routed it to stderr, which put it after
    # the PLAY RECAP whenever the two streams were captured separately
    # instead of directly ahead of the fatal line.
    src_dir = File.tempname("include-tasks-missing-stream")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include missing
            ansible.builtin.include_tasks: nosuch_tasks.yml
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: stdout, error: stderr, chdir: src_dir)
    out = stdout.to_s

    out.must_include("[ERROR]: Unable to retrieve file contents.")
    error_at = out.index!("[ERROR]:")
    fatal_at = out.index!("fatal: [localhost]")
    assert error_at < fatal_at, "the [ERROR] block must precede the fatal line"
    stderr.to_s.wont_include("[ERROR]:")
    status.exit_code.must_equal(2)

    FileUtils.rm_rf(src_dir)
  end

  it "counterfeits real's uncaught path_dwim TypeError crash on a non-string literal file path" do
    # Real 2.21.6 CRASHES on this shape: the linear strategy's include-result
    # processing feeds the tagged scalar to DataLoader.path_dwim, whose
    # len() raises uncaught - both tracebacks on STDERR, rc=250, no recap
    # and no per-host line (issue #1125). The stringified value never
    # reaches a file lookup, so whatever path "21" (or a bool's "True")
    # would have resolved to is as invisible to the output as the crash's
    # absence of any missing-file error.
    {21 => "_AnsibleTaggedInt", true => "bool"}.each do |literal, type_name|
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

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: stdout, error: stderr, chdir: src_dir)

      stdout.to_s.must_include("TASK [include missing]")
      stdout.to_s.wont_include("Unable to retrieve file contents.")
      stdout.to_s.wont_include("PLAY RECAP")
      stderr.to_s.must_include("[ERROR]: Unexpected Exception, this is probably a bug: object of type '#{type_name}' has no len()")
      stderr.to_s.must_include("TypeError: object of type '#{type_name}' has no len()")
      status.exit_code.must_equal(250)

      FileUtils.rm_rf(src_dir)
    end
  end
end
