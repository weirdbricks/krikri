require "file_utils"
require "../spec_helper"

# `role_name` (unprefixed) - real Ansible's own magic var for the name
# of the currently executing role. Only its `ansible_role_name` alias
# was ever set (executor_vars_context.cr), so a role referencing the
# unprefixed form directly (akkerman.docker's own "pin docker version"
# template: `{{ role_name }}`) raised "undefined" here while real
# Ansible resolved it fine.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_playbook(role_name : String, tasks_yaml : String) : String
  dir = File.tempname("role-name-magic-var")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "[g]\nlocal ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: g
      gather_facts: false
      roles:
        - #{role_name}
    YAML
  role_tasks_dir = File.join(dir, "roles", role_name, "tasks")
  Dir.mkdir_p(role_tasks_dir)
  File.write(File.join(role_tasks_dir, "main.yml"), tasks_yaml)

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "role_name magic var" do
  it "resolves the unprefixed role_name inside the role's own tasks" do
    out = run_playbook("myrole", <<-YAML)
      - name: t
        ansible.builtin.debug:
          msg: "name={{ role_name }}"
      YAML

    out.should contain("name=myrole")
    out.should_not contain("is undefined")
  end

  it "keeps the ansible_role_name alias working alongside it" do
    out = run_playbook("otherrole", <<-YAML)
      - name: t
        ansible.builtin.debug:
          msg: "both={{ role_name }}/{{ ansible_role_name }}"
      YAML

    out.should contain("both=otherrole/otherrole")
  end
end
