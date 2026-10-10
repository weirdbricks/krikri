require "file_utils"
require "../minitest_helper"

# Role names with SUBDIRECTORIES (`include_role: name: CiscoUcs.ucs/admin`):
# CiscoUcs.ucs (round 5410000) is a Galaxy role whose tasks/main.yml does
# `include_role: name: CiscoUcs.ucs/admin`, and admin/ is a full sub-role dir
# (own tasks/, meta/, defaults/) INSIDE the installed CiscoUcs.ucs checkout -
# admin's own tasks then include `CiscoUcs.ucs/admin/timezone` the same way.
# ansible-core joins the whole slash-containing name under each role search
# path (definition.py _load_role_path) and keeps the name verbatim in the
# banner (`TASK [CiscoUcs.ucs/admin/timezone : Configure Time Zone]`);
# krikri previously failed with "the role 'CiscoUcs.ucs/admin' was not
# found". All banner/error shapes below live-verified against
# ansible-playbook 2.19.11 before being encoded here.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def write_role(dir : String, name : String, & : String ->)
  role_dir = File.join(dir, "roles", name)
  FileUtils.mkdir_p(File.join(role_dir, "tasks"))
  yield role_dir
  role_dir
end

private def run_playbook(dir : String, playbook_name : String = "site.yml") : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, File.join(dir, playbook_name)], output: output, error: output)
  {status, output.to_s}
end

describe "slash-containing role names resolve as subdirectories inside a role checkout (subdir_role_test.cr)" do
  it "runs a two-level subdir role chain with banner names following the resolved subpath" do
    dir = PluginSpecHelper.tmp_path("subdir-role", Random::Secure.hex(4))
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    write_role(dir, "outer") do |role_dir|
      File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
        - include_role:
            name: outer/mid
        YAML
    end
    write_role(dir, "outer/mid") do |role_dir|
      File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
        - include_role:
            name: outer/mid/deep
        YAML
    end
    deep = write_role(dir, "outer/mid/deep") do |role_dir|
      File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
        - name: deep task
          ansible.builtin.debug:
            msg: "deep rp={{ role_path }}"
        YAML
    end
    File.write(File.join(dir, "site.yml"), <<-YAML)
        - hosts: localhost
          gather_facts: false
          roles:
            - outer
        YAML

    status, output = run_playbook(dir)

    status.success?.must_equal(true, output)
    output.must_include("TASK [include_role : outer/mid]", output)
    output.must_include("TASK [include_role : outer/mid/deep]", output)
    output.must_include("TASK [outer/mid/deep : deep task]", output)
    output.must_include(%("msg": "deep rp=#{deep}"), output)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "loads a meta/main.yml dependency written as a subdir name of the declaring role" do
    dir = PluginSpecHelper.tmp_path("subdir-role-dep", Random::Secure.hex(4))
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    write_role(dir, "outer") do |role_dir|
      FileUtils.mkdir_p(File.join(role_dir, "meta"))
      File.write(File.join(role_dir, "meta", "main.yml"), <<-YAML)
        dependencies:
          - role: outer/inner
        YAML
      File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
        - name: outer task
          ansible.builtin.debug:
            msg: outer
        YAML
    end
    write_role(dir, "outer/inner") do |role_dir|
      File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
        - name: inner task
          ansible.builtin.debug:
            msg: inner
        YAML
    end
    File.write(File.join(dir, "site.yml"), <<-YAML)
        - hosts: localhost
          gather_facts: false
          roles:
            - outer
        YAML

    status, output = run_playbook(dir)

    # Dependency tasks run BEFORE the declaring role's own tasks.
    status.success?.must_equal(true, output)
    output.must_include("TASK [outer/inner : inner task]", output)
    output.must_include("TASK [outer : outer task]", output)
    output.index("inner task").try { |i| i < (output.index("outer task") || 0) }.must_equal(true, output)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "keeps the not-found error unchanged for a genuinely missing subdirectory" do
    dir = PluginSpecHelper.tmp_path("subdir-role-missing", Random::Secure.hex(4))
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    write_role(dir, "outer") do |role_dir|
      File.write(File.join(role_dir, "tasks", "main.yml"), "- name: t\n  ansible.builtin.debug:\n    msg: hi\n")
    end
    File.write(File.join(dir, "site.yml"), <<-YAML)
        - hosts: localhost
          gather_facts: false
          tasks:
            - include_role:
                name: outer/nope
        YAML

    status, output = run_playbook(dir)

    status.success?.must_equal(false, output)
    output.must_include(
      "the role 'outer/nope' was not found in #{File.join(dir, "roles")}", output)
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
