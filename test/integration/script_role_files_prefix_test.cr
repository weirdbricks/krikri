require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug spans the
# task-executor's role-relative script src resolution, not the script
# plugin binary itself.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def write_script(path : String, body : String)
  File.write(path, body)
  File.chmod(path, 0o755)
end

private def run_playbook(src_dir : String, playbook : String)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
  {status, output.to_s}
end

describe "script: src: with the files/ prefix baked in resolves against the role" do
  it "runs script: files/x.sh --args from <role>/files/x.sh (issue #10 repro)" do
    # Real bug found benchmarking lukapetrovic-git.ubuntu_patch (issue
    # #10): its task is `script: files/get_upgraded_packages.py ...` with
    # the script at <role>/files/get_upgraded_packages.py. The resolver
    # only ever joined the src onto the role's files/ DIR
    # (<role>/files/files/...) and the playbook dir, so it missed the
    # role-root candidate its own miss error listed - ansible-playbook
    # 2.19.11 runs it (changed) via _find_needle's <role_root>/<src>
    # entry.
    src_dir = File.tempname("script-role-files-prefix")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "files"))
    write_script(File.join(src_dir, "roles", "myrole", "files", "x.sh"), "#!/bin/bash\necho ran \"$@\"\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Run role script with args
        ansible.builtin.script: files/x.sh --flag argvalue
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("changed: [localhost]")
    output.to_s.wont_include("Could not find or access")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still runs script: x.sh (no prefix) from <role>/files/x.sh" do
    src_dir = File.tempname("script-role-files-bare")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "files"))
    write_script(File.join(src_dir, "roles", "myrole", "files", "x.sh"), "#!/bin/bash\necho ran\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Run role script bare name
        ansible.builtin.script: x.sh
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("changed: [localhost]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "fails a missing role-relative script src with the full role-aware searched stack" do
    src_dir = File.tempname("script-role-files-miss")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "files"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Run missing role script
        ansible.builtin.script: files/nope.sh
        ignore_errors: true
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true)
    role = File.join(src_dir, "roles", "myrole")
    searched = "Searched in:\n\t#{role}/files/files/nope.sh\n\t#{role}/files/nope.sh\n\t#{role}/tasks/files/files/nope.sh\n\t#{role}/tasks/files/nope.sh\n\t#{src_dir}/files/files/nope.sh\n\t#{src_dir}/files/nope.sh on the Ansible Controller."
    output.to_s.must_include(searched)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
