require "file_utils"
require "../spec_helper"

# include_vars: with a failing templated path must fail the include_vars
# task ITSELF with an undefined-variable error, matching real Ansible -
# verified live against ansible-core 2.19.4 with minimal repros:
#
#   - `include_vars: "{{ users }}"` with no `users` anywhere:
#       "[ERROR]: Task failed: Finalization of task args for
#       'ansible.builtin.include_vars' failed: Error while resolving
#       value for '_raw_params': 'users' is undefined" (rc=2)
#   - `include_vars: "{{ lookup('first_found', params) }}"` with
#       `files: ['{{ ansible_facts.os_family }}.yml', 'default.yml']`
#       and no gathered facts: fails the include_vars task with
#       "object of type 'dict' has no attribute 'os_family'" - it does
#       NOT silently fall through to default.yml and load nothing.
#
# This engine used to render the path leniently to the literal text
# "undefined" and fail with "include_vars: file not found: undefined"
# (gantsign.oh-my-zsh, round 192's cosmetic-differences entry in
# KNOWN_MISSING.md), or worse, silently "succeed" loading an empty
# fallback file. Real Ansible's own "Finalization of task args ... failed:
# Error while resolving value for '_raw_params':" wrapper is the same 2.19
# presentation layer every other module's undefined-arg failure already
# drops (this engine reports the bare cause text, "'users' is undefined" -
# identical to its convention for every other module).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Builds a throwaway role tree (roles/probe/{tasks,vars/os_family}) and
# runs the given site playbook from it, so a first_found `paths:`
# entry resolves the same way it does in a real role.
private def run_in_role_tree(site_yaml : String, debian_vars = "os_specific_var: from_debian_yml\n")
  dir = File.tempname("include-vars-undefined-path", ".d")
  FileUtils.mkdir_p(File.join(dir, "roles", "probe", "tasks"))
  FileUtils.mkdir_p(File.join(dir, "roles", "probe", "vars", "os_family"))
  File.write(File.join(dir, "roles", "probe", "tasks", "main.yml"), <<-YAML)
    ---
    - name: Setting OS variables
      ansible.builtin.include_vars: "{{ lookup('ansible.builtin.first_found', params) }}"
      vars:
        params:
          files:
            - '{{ ansible_facts.os_family }}.yml'
            - default.yml
          paths:
            - vars/os_family
    - name: show loaded var
      ansible.builtin.debug:
        msg: "{{ os_specific_var }}"
    YAML
  File.write(File.join(dir, "roles", "probe", "vars", "os_family", "Debian.yml"), debian_vars)
  File.write(File.join(dir, "roles", "probe", "vars", "os_family", "default.yml"), "---\n")
  playbook = File.join(dir, "site.yml")
  File.write(playbook, site_yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: dir)
  {status, output.to_s}
ensure
  FileUtils.rm_r(dir) if dir && File.exists?(dir)
end

private def run_playbook(yaml : String)
  playbook = File.tempname("include-vars-undefined-path", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "include_vars: with a failing templated path" do
  it "fails the include_vars task itself when the path variable is undefined" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: direct undefined path
            ansible.builtin.include_vars: "{{ users }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'users' is undefined")
    output.should_not contain("file not found: undefined")
  end

  it "does not silently fall through to a later first_found candidate when an earlier candidate's template is undefined" do
    status, output = run_in_role_tree(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - probe
      YAML

    status.exit_code.should eq(2)
    output.should contain("is undefined")
    output.should_not contain("from_debian_yml")
  end

  it "still resolves a fully-defined first_found lookup path" do
    status, output = run_in_role_tree(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - probe
      YAML

    status.success?.should be_true
    output.should contain("from_debian_yml")
  end
end
