require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the Origin the
# role-not-found block points at depends on the executor's runtime
# value-lineage resolution, which needs an end-to-end run.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

describe "include_role: templated role-name Origin lineage" do
  it "points a bare-variable name's role-not-found Origin at the variable value's defining position" do
    # Real 2.19.11 tags every YAML-sourced scalar with its defining source
    # position and the tag survives templating, so a templated role name
    # that fails role resolution reports the Origin of the VALUE the name
    # resolved through - `{{ lib_name }}` reports the defaults file's own
    # value token (1:11), not the include task's name value (issue #810).
    src_dir = File.tempname("include-role-name-origin-bare")
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "tasks"))
    File.write(File.join(src_dir, "roles", "outer", "defaults", "main.yml"), "lib_name: missing_role_xyz\n")
    File.write(File.join(src_dir, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - include_role:
          name: "{{ lib_name }}"
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

    output.must_include("[ERROR]: the role 'missing_role_xyz' was not found in ")
    output.must_include("Origin: #{src_dir}/roles/outer/defaults/main.yml:1:11")
    output.must_include("1 lib_name: missing_role_xyz")
    output.must_include("            ^ column 11")

    FileUtils.rm_rf(src_dir)
  end

  it "points a dict-subscript name's role-not-found Origin at the mapped value's own position" do
    # vbotka.rsnapshot's real shape (issue #810): the include task names
    # `{{ rsnapshot_ansible_lib[ansible_role_name] }}`, and real reports
    # the Origin of the mapped VALUE's scalar inside the defining file -
    # a position the include task's own source map knows nothing about.
    src_dir = File.tempname("include-role-name-origin-subscript")
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "tasks"))
    File.write(File.join(src_dir, "roles", "outer", "defaults", "main.yml"), "lib_map:\n  k1: missing_one\n  k2: missing_two\n")
    File.write(File.join(src_dir, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - include_role:
          name: "{{ lib_map['k2'] }}"
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

    output.must_include("[ERROR]: the role 'missing_two' was not found in ")
    output.must_include("Origin: #{src_dir}/roles/outer/defaults/main.yml:3:7")
    output.must_include("3   k2: missing_two")
    output.must_include("      ^ column 7")

    FileUtils.rm_rf(src_dir)
  end

  it "keeps the name value's own Origin for a filter-derived name real cannot attribute either" do
    # A filter chain derives a NEW value, which drops real's origin tag -
    # real (live-verified 2.19.11, `{{ lib_name | upper }}`) falls back to
    # the name value's own position in the include task's file, which is
    # exactly what this engine printed before value lineage existed. The
    # unattributable shapes must stay on that fallback, never grow a
    # guessed origin.
    src_dir = File.tempname("include-role-name-origin-filter")
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "tasks"))
    File.write(File.join(src_dir, "roles", "outer", "defaults", "main.yml"), "lib_name: missing_role_xyz\n")
    File.write(File.join(src_dir, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - include_role:
          name: "{{ lib_name | upper }}"
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

    output.must_include("[ERROR]: the role 'MISSING_ROLE_XYZ' was not found in ")
    output.must_include("Origin: #{src_dir}/roles/outer/tasks/main.yml:2:11")
    output.must_include("2     name: \"{{ lib_name | upper }}\"")
    output.must_include("            ^ column 11")

    FileUtils.rm_rf(src_dir)
  end
end
